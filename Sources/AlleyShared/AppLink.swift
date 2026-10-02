import Foundation

/// 앱 하나를 가리키는 공유 주소 (ADR-0072).
///
/// 주소는 두 가지다. 사람이 슬랙에 붙이는 것은 서버의 웹 페이지(`/a/<앱 ID>`)이고,
/// 그 페이지가 스토어 앱을 부를 때 쓰는 것이 커스텀 스킴(`<scheme>://apps/<앱 ID>`)이다.
/// 서버가 만들고 스토어 앱이 읽으므로 둘 다 여기서만 정한다.
///
/// **번들 ID 가 아니라 앱 ID 를 쓴다.** 스토어 앱이 앱을 이미 ID 로 다루고, 주소를
/// 지어서 출시 전 앱이 있는지 떠볼 수 없다.
public enum AppLink {
    /// 웹 페이지 경로의 첫 마디. 슬랙에 붙을 주소라 짧게 둔다.
    public static let webPathComponent = "a"

    /// 커스텀 스킴 URL 의 호스트. 로그인 콜백(`auth`)과 겹치지 않아야 한다.
    public static let schemeHost = "apps"

    /// `/a/<앱 ID>`
    public static func webPath(appID: UUID) -> String {
        "/\(webPathComponent)/\(appID.uuidString.lowercased())"
    }

    /// `<scheme>://apps/<앱 ID>`
    public static func storeAppURL(scheme: String, appID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = schemeHost
        components.path = "/\(appID.uuidString.lowercased())"
        return components.url
    }

    /// 스토어 앱이 받은 URL 에서 앱 ID 를 꺼낸다. 앱 링크가 아니면 nil.
    ///
    /// 스킴은 보지 않는다. 이 URL 은 스토어 앱이 등록한 스킴으로만 들어온다.
    public static func appID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == schemeHost
        else { return nil }
        let segments = components.path.split(separator: "/")
        guard segments.count == 1 else { return nil }
        return UUID(uuidString: String(segments[0]))
    }
}
