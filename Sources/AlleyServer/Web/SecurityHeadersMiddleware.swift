import Foundation
import Vapor

/// 모든 응답에 붙는 보안 헤더.
///
/// `OriginCheckMiddleware` 는 **다른 사이트가 보낸** 요청을 막는다. 다른 사이트가
/// 우리 화면을 iframe 으로 덮어놓고 사용자 손으로 누르게 만드는 것(클릭재킹)은 막지
/// 못한다. 그때 브라우저가 보내는 `Origin` 은 우리 것이라 검사를 그냥 통과한다.
/// 출시(`/apps/:id/versions/:id/release`)와 역할 변경(`/admin/users/:id/role`) 이
/// 전부 POST 폼 하나라, 덮어두고 한 번 누르게 하면 그것으로 끝난다.
///
/// 그 문은 `frame-ancestors` 로만 닫힌다.
///
/// **모든 응답에 붙인다.** 오류 화면에도 폼은 없지만, 경로마다 붙는지 아닌지를 따지기
/// 시작하면 새로 만든 경로에서 빠지는 날이 온다. 조건 없이 붙이는 편이 싸고 안전하다.
public struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// 브라우저가 우리 화면에서 직접 붙는 스토리지의 출처.
    ///
    /// 업로드는 presigned URL 로 스토리지에 직접 `PUT` 하고(`Public/upload.js`),
    /// 피드백 스크린샷은 presigned URL 을 `img` 로 띄운다. 여기가 비어 있으면 업로드가
    /// **아무 오류 없이** 멈춘다. CSP 위반은 브라우저 콘솔에만 찍히고 화면에는 아무 일도
    /// 일어나지 않아서, 왜 업로드가 안 되는지 한참 헤매게 된다.
    private let storageOrigin: String?

    /// - Parameter storageOrigin: `scheme://host[:port]` 형태.
    ///   ``storageOrigin(for:)`` 로 만든다.
    public init(storageOrigin: String? = nil) {
        self.storageOrigin = storageOrigin
    }

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)

        // 선언한 Content-Type 을 브라우저가 제 맘대로 다시 추측하지 못하게 한다.
        // 업로더가 올린 파일이 우리 출처에서 HTML 로 해석되는 길을 막는다.
        response.headers.replaceOrAdd(name: .xContentTypeOptions, value: "nosniff")

        // 우리 화면 안에서 옮겨다닐 때는 Referer 를 그대로 두고, 밖으로 나갈 때만 뗀다.
        //
        // `no-referrer` 로 다 떼지 않는 이유가 있다. `OriginCheckMiddleware` 가
        // `Origin` 이 없을 때 `Referer` 를 대신 본다. 다 떼면 그 대비책이 함께 죽는다.
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "same-origin")

        response.headers.replaceOrAdd(name: .contentSecurityPolicy, value: policy)

        // HSTS 는 여기서 붙이지 않는다.
        //
        // TLS 를 끊는 자리(인그레스·리버스 프록시)가 이미 붙이는 경우가 많고, 그러면
        // `max-age` 가 다른 헤더가 둘 나간다. 게다가 이 서버는 자기가 https 로
        // 서비스되는지 알지 못한다. http 로 뜬 서버가 HSTS 를 붙이면 그 호스트로
        // 다시는 http 로 붙지 못하게 되고, 되돌리려면 브라우저마다 손으로 지워야 한다.
        // 붙일 곳은 TLS 를 끊는 자리다. `docs/setup.md` 에 적어뒀다.
        //
        // `X-Frame-Options` 도 붙이지 않는다. `frame-ancestors` 가 그것을 대체하고,
        // 같은 뜻을 두 헤더로 적으면 한쪽만 고치는 날이 온다.

        return response
    }

    /// 실제 화면이 쓰는 것만 연다.
    ///
    /// 템플릿을 읽고 맞춘 값이다. 화면을 고칠 때 여기도 같이 봐야 한다.
    private var policy: String {
        let storage = storageOrigin.map { " \($0)" } ?? ""

        return [
            // 아래에서 따로 열지 않은 것은 전부 막는다. 새 종류의 자원을 쓰기 시작하면
            // 조용히 통과하는 대신 눈에 띄게 막힌다.
            "default-src 'none'",
            // 스크립트는 외부 파일 하나뿐이다(`Public/upload.js`). 인라인 스크립트는
            // 어느 템플릿에도 없고, 앞으로도 넣지 않는다.
            "script-src 'self'",
            // `layout.leaf` 가 강조색을 인라인 `<style>` 로 넣는다. 그 값은 관리자가
            // 설정 화면에서 정하는 것이라 미리 해시할 수 없고, nonce 를 쓰려면 모든
            // 화면의 렌더 경로에 값을 하나씩 실어 날라야 한다.
            //
            // 대신 그 값은 저장할 때 `#RRGGBB` 형식으로 좁혀둔다
            // (`StoreSettingsValidation`). 스타일 주입으로 할 수 있는 일과 스크립트
            // 실행으로 할 수 있는 일은 크기가 다르고, 여기서 막고 싶은 것은 뒤쪽이다.
            "style-src 'self' 'unsafe-inline'",
            // 피드백 스크린샷은 스토리지의 presigned URL 이고, 스토어 로고는 관리자가
            // 설정 화면에서 넣는 아무 주소다. 로고 호스트는 서버가 미리 알 수 없어서
            // https 를 통째로 연다. 이미지는 실행되지 않는다.
            //
            // 로고를 `http://` 로 적으면 여기서 막힌다. https 로 적어야 한다.
            // (https 로 서비스되는 콘솔에서는 CSP 와 무관하게 브라우저가 이미 막는다.)
            "img-src 'self' data: https:\(storage)",
            // 업로드가 스토리지로 직접 `PUT` 한다(`Public/upload.js`). 나머지 요청은
            // 전부 같은 출처다. 스토리지 주소는 설정에서 정확히 계산해 넣으므로
            // 여기서는 https 를 통째로 열지 않는다.
            "connect-src 'self'\(storage)",
            // 폼은 전부 우리 경로로 간다. 주입된 폼이 밖으로 값을 보내는 것을 막는다.
            "form-action 'self'",
            // 우리 화면을 다른 사이트가 iframe 으로 덮지 못하게 한다. 이 미들웨어를
            // 만든 이유다.
            "frame-ancestors 'none'",
            // 상대 주소의 기준을 바꿔치기하지 못하게 한다.
            "base-uri 'none'",
        ].joined(separator: "; ")
    }
}

extension SecurityHeadersMiddleware {
    /// 브라우저가 실제로 붙을 스토리지의 출처를 설정에서 계산한다.
    ///
    /// presigned URL 을 만드는 것과 **같은 함수**로 주소를 얻는다. 여기서 규칙을 다시
    /// 쓰면 언젠가 둘이 어긋나고, 어긋난 날 증상은 "업로드가 조용히 안 됨" 이다.
    /// 엔드포인트를 안 준 AWS S3 (`https://{버킷}.s3.{리전}.amazonaws.com`)와 가상 호스트
    /// 방식으로 버킷이 호스트 앞에 붙는 경우까지 그 함수가 이미 다룬다.
    ///
    /// 주소를 만들지 못하면 `nil` 을 준다. 그 설정으로는 스토리지 자체가 동작하지
    /// 않으므로, CSP 가 아니라 스토리지 쪽에서 먼저 실패한다.
    static func storageOrigin(for config: AppConfig.StorageConfig) -> String? {
        guard let base = try? ArtifactStorage.objectBase(config: config),
              let scheme = base.scheme,
              let host = base.host
        else {
            return nil
        }
        if let port = base.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}
