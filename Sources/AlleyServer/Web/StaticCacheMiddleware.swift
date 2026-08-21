import Vapor

/// 정적 파일에 `Cache-Control: no-cache` 를 붙인다.
///
/// `FileMiddleware` 는 `ETag` 와 `Last-Modified` 만 보내고 `Cache-Control` 은 보내지
/// 않는다. 그러면 브라우저가 **자기 판단으로** 캐시한다(보통 `Last-Modified` 이후
/// 경과 시간의 10% 정도). 조건부 요청조차 보내지 않는 구간이 생긴다.
///
/// 그 결과 고친 CSS 가 반영되지 않는다. 개발 중에는 왜 스타일이 안 먹는지 한참
/// 헤매게 되고, 배포 후에는 이미 파일을 받아둔 사람에게 수정이 닿지 않는다.
/// 둘 다 조용히 일어나서 알아채기 어렵다.
///
/// `no-cache` 는 "캐시하지 말라"가 아니라 **"쓸 때마다 서버에 물어보라"** 는 뜻이다.
/// `ETag` 가 그대로면 304 로 끝나므로 본문은 다시 내려가지 않는다. 정적 파일 몇 개짜리
/// 콘솔에서 이 왕복은 무시할 수 있다.
///
/// 파일이 많아져서 이 왕복이 부담되면, 주소에 지문을 붙이고(`console.css?v=<해시>`)
/// `max-age` 를 길게 주는 방식으로 바꾼다. 그때는 지문을 만드는 단계가 필요하다.
public struct StaticCacheMiddleware: AsyncMiddleware {
    /// 정적 파일로 볼 확장자.
    ///
    /// 경로가 아니라 확장자로 판단한다. `Public/` 아래 구조가 바뀌어도 따라가지 않아도 된다.
    private static let assetExtensions: Set<String> = [
        "css", "js", "map", "png", "jpg", "jpeg", "gif", "svg", "webp", "ico",
        "woff", "woff2", "ttf", "otf",
    ]

    public init() {}

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)

        guard let extensionName = request.url.path.split(separator: ".").last?.lowercased(),
              Self.assetExtensions.contains(String(extensionName)),
              response.status == .ok || response.status == .notModified
        else {
            return response
        }

        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return response
    }
}
