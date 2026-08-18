import AlleyShared
import Vapor

/// 쿠키로 인증된 상태 변경 요청에 `Origin` 이 우리 출처인지 확인한다.
///
/// ADR-0010 에서 CSRF 방어를 `SameSite=Lax` 에 맡겼는데, 그 방어의 실체가 쿠키를
/// 만들 때 붙이는 속성 한 줄뿐이라 코드 어디에도 보이지 않는다는 것이 약점이었다.
/// 누가 그 줄을 지우거나 `.none` 으로 바꾸면 조용히 뚫린다.
///
/// 이 미들웨어가 그 방어를 코드로 드러낸다. 두 겹이 되므로 한쪽이 무너져도 남는다.
///
/// **헤더로 인증하는 요청은 건드리지 않는다.** 스토어 앱과 CLI 는 `Origin` 을 보내지
/// 않고, 보낼 이유도 없다. 브라우저가 자동으로 쿠키를 붙이는 것이 CSRF 의 조건이므로
/// 쿠키로 들어온 요청만 검사하면 된다.
public struct OriginCheckMiddleware: AsyncMiddleware {
    public init() {}

    /// 상태를 바꾸는 메서드. 브라우저는 이들에 대해 언제나 `Origin` 을 보낸다.
    ///
    /// `HTTPMethod` 는 Hashable 이 아니라 Set 으로 둘 수 없다.
    private static let guardedMethods: [HTTPMethod] = [.POST, .PUT, .PATCH, .DELETE]

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard Self.guardedMethods.contains(request.method) else {
            return try await next.respond(to: request)
        }
        // 헤더를 명시한 요청은 브라우저의 자동 쿠키가 아니다.
        guard request.headers.bearerAuthorization == nil,
              request.cookies[sessionCookieName] != nil
        else {
            return try await next.respond(to: request)
        }

        guard let claimed = declaredOrigin(of: request) else {
            request.logger.warning(
                "Origin 없는 쿠키 인증 요청 거부 [method: \(request.method), path: \(request.url.path)]"
            )
            throw Abort(.forbidden, reason: "요청 출처를 확인할 수 없습니다. 페이지를 새로 고친 뒤 다시 시도해주세요.")
        }

        guard allowedOrigins(for: request).contains(claimed) else {
            request.logger.warning(
                "다른 출처에서 온 쿠키 인증 요청 거부 [origin: \(claimed), path: \(request.url.path)]"
            )
            throw Abort(.forbidden, reason: "다른 사이트에서 시작된 요청입니다.")
        }

        return try await next.respond(to: request)
    }

    /// 요청이 스스로 밝힌 출처.
    ///
    /// `Origin` 이 원칙이고, 없으면 `Referer` 에서 출처만 잘라 쓴다. 일부 프록시가
    /// `Origin` 을 떼는 경우가 있어서 두는 대비책이다.
    private func declaredOrigin(of request: Request) -> String? {
        if let origin = request.headers.first(name: .origin), origin != "null" {
            return normalize(origin)
        }
        if let referer = request.headers.first(name: .referer),
           let components = URLComponents(string: referer)
        {
            return origin(from: components)
        }
        return nil
    }

    /// 우리 출처로 인정할 목록.
    ///
    /// 요청의 `Host` 를 쓰는 이유는 공격자 페이지가 이 값을 바꿀 수 없기 때문이다.
    /// 브라우저가 실제로 접속한 주소를 그대로 적는다. 설정된 공개 주소도 함께 인정해서
    /// 프록시 뒤에서 `Host` 가 달라지는 구성에서도 동작하게 한다.
    private func allowedOrigins(for request: Request) -> Set<String> {
        var allowed = Set<String>()

        if let host = request.headers.first(name: .host) {
            let isSecure = request.url.scheme == "https"
                || request.headers.first(name: .init("X-Forwarded-Proto")) == "https"
            allowed.insert(normalize("\(isSecure ? "https" : "http")://\(host)"))
            // 프록시가 종단한 경우 원래 요청은 https 였을 수 있다. 양쪽 다 인정한다.
            allowed.insert(normalize("https://\(host)"))
            allowed.insert(normalize("http://\(host)"))
        }

        if let components = URLComponents(string: request.application.alleyConfig.publicBaseURL),
           let configured = origin(from: components)
        {
            allowed.insert(configured)
        }
        return allowed
    }

    private func origin(from components: URLComponents) -> String? {
        guard let scheme = components.scheme, let host = components.host else { return nil }
        if let port = components.port {
            return normalize("\(scheme)://\(host):\(port)")
        }
        return normalize("\(scheme)://\(host)")
    }

    /// 기본 포트를 떼서 `http://a` 와 `http://a:80` 을 같게 본다.
    private func normalize(_ origin: String) -> String {
        let lowered = origin.lowercased()
        if lowered.hasPrefix("http://"), lowered.hasSuffix(":80") {
            return String(lowered.dropLast(3))
        }
        if lowered.hasPrefix("https://"), lowered.hasSuffix(":443") {
            return String(lowered.dropLast(4))
        }
        return lowered
    }
}
