import AlleyShared
import Fluent
import Vapor

/// 웹 콘솔 화면.
///
/// JSON API 와 같은 서버에 살지만 컨트롤러를 나눈다. 하나에 섞으면 어떤 응답이
/// HTML 이고 어떤 것이 JSON 인지 읽어서 알기 어려워진다.
///
/// 화면은 API 를 HTTP 로 다시 부르지 않고 같은 프로세스의 모델을 직접 읽는다.
/// 자기 자신에게 요청을 보내면 커넥션과 직렬화를 왕복으로 낭비한다.
public struct WebController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        // 세션이 있으면 사용자를 붙이되, 없다고 막지는 않는다.
        // 로그인 화면 자체는 로그인 없이 봐야 한다.
        let pages = routes.grouped(SessionAuthenticator())

        pages.get(use: home)
        pages.post("logout", use: logout)
    }

    /// 첫 화면. 로그인 상태에 따라 갈린다.
    @Sendable
    func home(request: Request) async throws -> View {
        if let user = request.auth.get(User.self) {
            return try await request.view.render(
                "home",
                HomeContext(
                    page: try await request.pageContext(),
                    canPublish: user.role.canPublish,
                    canAdminister: user.role.canAdminister
                )
            ).get()
        }
        let settings = try await request.storeSettings()
        return try await request.view.render(
            "login",
            LoginContext(
                page: try await request.pageContext(title: "로그인"),
                allowedEmailDomains: settings.allowedEmailDomains,
                authorizationPath: APIPath.googleAuthorize
            )
        ).get()
    }

    /// 로그아웃.
    ///
    /// 쿠키를 지우는 것뿐이다. 발급된 세션 토큰 자체는 만료까지 유효하다
    /// (ADR-0008 의 한계). 남의 손에 넘어간 토큰을 끊으려면 토큰 무효화가 필요하다.
    ///
    /// `GET` 이 아니라 `POST` 인 이유는, 브라우저나 확장이 미리 가져오는 링크를
    /// 누르는 것만으로 로그아웃되는 일을 막기 위해서다.
    @Sendable
    func logout(request: Request) async throws -> Response {
        let response = request.redirect(to: "/")
        response.cookies[sessionCookieName] = .expired
        return response
    }
}

// MARK: - 화면별 데이터

struct HomeContext: Encodable {
    var page: PageContext
    var canPublish: Bool
    var canAdminister: Bool
}

struct LoginContext: Encodable {
    var page: PageContext
    var allowedEmailDomains: [String]
    var authorizationPath: String
}

extension HTTPCookies.Value {
    /// 즉시 만료되는 쿠키. 브라우저가 지우게 한다.
    static var expired: HTTPCookies.Value {
        HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/",
            isHTTPOnly: true,
            sameSite: .lax
        )
    }
}
