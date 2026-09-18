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
    ///
    /// 로그인해 있으면 앱 목록으로 보낸다. 콘솔에 들어와서 하려는 일은 대개 앱을
    /// 보거나 올리는 것이라, 중간에 한 장을 더 두면 매번 한 번씩 더 눌러야 한다.
    @Sendable
    func home(request: Request) async throws -> Response {
        if request.auth.has(User.self) {
            return request.redirect(to: "/apps")
        }

        let settings = try await request.storeSettings()
        let view = try await request.view.render(
            "login",
            LoginContext(
                page: try await request.pageContext(title: "로그인"),
                allowedEmailDomains: settings.allowedEmailDomains,
                authorizationPath: APIPath.googleAuthorize,
                // 공급자가 Google 이 아닐 수 있다 (ADR-0047). 버튼에 "Google" 이
                // 적혀 있는데 다른 곳으로 가면 사용자가 잘못 누른 줄 안다.
                isGoogle: request.application.alleyConfig.oauth.isGoogle,
                storeAppPath: StoreAppGetController.path
            )
        ).get()

        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
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
        let response = request.redirect(to: await Self.logoutDestination(on: request))
        response.cookies[sessionCookieName] = .expired
        // 공급자에게 돌려줬으면 더 들고 있을 이유가 없다.
        response.cookies[providerIDTokenCookieName] = .expired
        // 다음 로그인에서 공급자에게 다시 물어보게 한다. 이것이 없으면 SSO 세션이
        // 남아 있어 로그인 버튼 한 번으로 같은 계정에 그대로 들어간다.
        response.cookies[reauthenticationCookieName] = HTTPCookies.Value(
            string: "1",
            // 로그아웃하고 바로 다시 들어오는 흐름만 잡으면 된다. 길게 두면 한참 뒤의
            // 로그인까지 재인증을 요구한다.
            maxAge: 600,
            path: "/",
            isSecure: request.application.alleyConfig.publicBaseURL.hasPrefix("https://"),
            isHTTPOnly: true,
            sameSite: .lax
        )
        return response
    }

    /// 쿠키를 지운 뒤 어디로 보낼지.
    ///
    /// **기본은 홈이다.** 공급자 세션까지 끊는 것은 켠 스토어에서만 한다
    /// (`OIDC_LOGOUT_ENDS_PROVIDER_SESSION`). 같은 IdP 를 쓰는 다른 사내 도구에서도
    /// 로그아웃되기 때문이다. 공용 맥을 여럿이 쓰는 곳에서는 그것이 맞고, 개인 맥만
    /// 쓰는 곳에서는 과하다. 조직이 정할 일이다.
    ///
    /// 켜지 않아도 다음 로그인은 재인증을 거친다 (`reauthenticationCookieName`).
    /// 끊는 것과 다시 묻는 것의 차이는 "다른 사람이 그 브라우저로 무엇을 할 수
    /// 있는가" 다.
    ///
    /// 공급자에게 물어보지 못하면 그냥 홈으로 보낸다. **로그아웃이 실패하는 것보다
    /// 덜 지워지는 편이 낫다.** 우리 쿠키는 이미 지워졌다.
    private static func logoutDestination(on request: Request) async -> String {
        let config = request.application.alleyConfig
        guard config.oauth.endsProviderSessionOnLogout else { return "/" }

        do {
            let metadata = try await request.application.oidcDirectory.metadata(
                using: request.client, logger: request.logger
            )
            let provider = OIDCProvider(config: config.oauth, metadata: metadata)
            return provider.endSessionURL(
                postLogoutRedirectURI: config.publicBaseURL,
                idTokenHint: request.cookies[providerIDTokenCookieName]?.string
            ) ?? "/"
        } catch {
            request.logger.warning("공급자 세션 종료 주소를 알아내지 못했습니다: \(error)")
            return "/"
        }
    }
}

// MARK: - 화면별 데이터

struct LoginContext: Encodable {
    var page: PageContext
    var allowedEmailDomains: [String]
    var authorizationPath: String
    /// 로그인 버튼에 공급자 이름을 적을지.
    ///
    /// Google 만 이름을 적는다. 그 버튼은 사람들이 눈으로 찾는 것이고, 다른
    /// 공급자는 조직마다 부르는 이름이 달라서(회사 계정, SSO, Okta…) 우리가
    /// 정해줄 수 없다.
    var isGoogle: Bool
    /// 스토어 앱을 받는 공개 페이지의 경로 (ADR-0049).
    ///
    /// 앱을 받으러 왔는데 로그인 화면에 떨어진 사람이 있다. 로그인해서 콘솔에
    /// 들어가봐야 거기는 앱을 올리는 사람이 보는 화면이다.
    var storeAppPath: String
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
