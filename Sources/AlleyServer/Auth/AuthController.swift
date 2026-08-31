import AlleyShared
import Fluent
import JWT
import Vapor

/// 로그인 관련 경로.
///
/// 웹 콘솔과 스토어 앱이 **같은 경로**를 쓴다. 앱은 `ASWebAuthenticationSession` 으로
/// 이 서버의 로그인 주소를 열 뿐이고, Google 과의 왕복은 서버가 처리한다.
/// 그래서 앱 바이너리에는 Google 클라이언트 정보가 들어가지 않는다.
public struct AuthController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        routes.get(APIPath.googleAuthorize.pathComponents, use: authorize)
        routes.get(APIPath.googleCallback.pathComponents, use: callback)
        routes.post(APIPath.tokenExchange.pathComponents, use: exchangeToken)

        let authenticated = routes.grouped(SessionAuthenticator(), User.guardMiddleware())
        authenticated.get(APIPath.currentUser.pathComponents, use: currentUser)
    }

    // MARK: - 로그인 시작

    /// Google 로그인 화면으로 보낸다.
    ///
    /// `?client=app` 으로 부르면 인증 후 커스텀 URL 스킴으로 돌려보낸다.
    /// 스토어 앱이 이 형태로 부른다.
    @Sendable
    func authorize(request: Request) async throws -> Response {
        let config = request.application.alleyConfig
        let target: OAuthStateToken.Target =
            request.query[String.self, at: APIPath.clientQueryItem] == APIPath.appClient
            ? .app : .web

        let state = try await request.jwt.sign(OAuthStateToken(target: target))
        let url = GoogleOAuth(config: config.oauth).authorizationURL(state: state)
        return request.redirect(to: url)
    }

    // MARK: - Google 콜백

    @Sendable
    func callback(request: Request) async throws -> Response {
        let config = request.application.alleyConfig

        guard let code = request.query[String.self, at: "code"], !code.isEmpty else {
            // 사용자가 동의를 거부하면 code 없이 error 가 온다.
            let reason = request.query[String.self, at: "error"] ?? "인가 코드가 없습니다."
            throw Abort(.badRequest, reason: "로그인이 완료되지 않았습니다: \(reason)")
        }
        guard let rawState = request.query[String.self, at: "state"], !rawState.isEmpty else {
            throw Abort(.badRequest, reason: "state 값이 없습니다.")
        }

        // 우리가 서명한 state 인지 확인한다. 위조된 요청은 여기서 걸린다.
        let state: OAuthStateToken
        do {
            state = try await request.jwt.verify(rawState, as: OAuthStateToken.self)
        } catch {
            request.logger.warning("state 검증 실패: \(error)")
            throw Abort(.badRequest, reason: "로그인 요청이 만료되었거나 유효하지 않습니다. 다시 시도해주세요.")
        }

        let tokens = try await GoogleOAuth(config: config.oauth)
            .exchange(code: code, client: request.client)

        // ID 토큰은 Google 의 공개키로 서명을 검증하고 audience 가 우리 클라이언트인지 확인한다.
        // 도메인 검증은 여러 도메인을 허용해야 해서 아래에서 직접 한다.
        let identity = try await request.jwt.google.verify(
            tokens.idToken,
            applicationIdentifier: config.oauth.clientID
        )

        let settings = try await request.storeSettings()
        let policy = EmailDomainPolicy(allowedDomains: settings.allowedEmailDomains)
        let email: String
        do {
            email = try policy.admit(
                email: identity.email,
                emailVerified: identity.emailVerified?.value,
                hostedDomain: identity.hostedDomain?.value
            )
        } catch {
            request.logger.notice("로그인 거부: \(error)")
            throw Abort(.forbidden, reason: String(describing: error))
        }

        let user = try await upsertUser(
            request: request,
            googleSubject: identity.subject.value,
            email: email,
            name: identity.name ?? email,
            avatarURL: identity.picture
        )
        let userID = try user.requireID()

        switch state.target {
        case .web:
            // 웹은 세션 토큰을 HttpOnly 쿠키로 받는다. 자바스크립트가 읽지 못하게 한다.
            let token = try await signSession(request: request, userID: userID)
            let response = request.redirect(to: "/")
            response.cookies[sessionCookieName] = sessionCookie(
                token: token,
                ttl: config.security.sessionTTL,
                isSecure: config.publicBaseURL.hasPrefix("https://")
            )
            return response

        case .app:
            // 앱은 일회용 코드만 받아가고, 세션 토큰은 별도 POST 로 교환한다.
            let (plaintext, model) = AuthCode.issue(userID: userID)
            try await model.save(on: request.db)
            var components = URLComponents()
            components.scheme = config.store.callbackURLScheme
            components.host = "auth"
            components.queryItems = [.init(name: "code", value: plaintext)]
            return request.redirect(to: components.url!.absoluteString)
        }
    }

    // MARK: - 앱 토큰 교환

    @Sendable
    func exchangeToken(request: Request) async throws -> TokenExchangeResponse {
        let payload = try request.content.decode(TokenExchangeRequest.self)
        let now = Date()

        guard let authCode = try await AuthCode.query(on: request.db)
            .filter(\.$codeHash == AuthCode.hash(payload.code))
            .with(\.$user)
            .first()
        else {
            throw Abort(.unauthorized, reason: "코드가 유효하지 않습니다.")
        }

        guard authCode.isUsable(at: now) else {
            throw Abort(.unauthorized, reason: "코드가 이미 사용되었거나 만료되었습니다.")
        }

        // 먼저 소진 처리한다. 같은 코드로 두 번 토큰을 받는 일을 막는다.
        authCode.consumedAt = now
        try await authCode.save(on: request.db)

        let user = authCode.user
        let token = try await signSession(request: request, userID: try user.requireID())
        return TokenExchangeResponse(
            token: token,
            expiresIn: request.application.alleyConfig.security.sessionTTL,
            user: try user.toDTO()
        )
    }

    // MARK: - 현재 사용자

    @Sendable
    func currentUser(request: Request) async throws -> UserDTO {
        try request.requireUser().toDTO()
    }

    // MARK: - 보조

    private func signSession(request: Request, userID: UUID) async throws -> String {
        let ttl = TimeInterval(request.application.alleyConfig.security.sessionTTL)
        return try await request.jwt.sign(
            SessionToken(userID: userID, issuedAt: Date(), ttl: ttl)
        )
    }

    private func sessionCookie(token: String, ttl: Int, isSecure: Bool) -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: token,
            expires: Date().addingTimeInterval(TimeInterval(ttl)),
            maxAge: ttl,
            path: "/",
            isSecure: isSecure,
            isHTTPOnly: true,
            sameSite: .lax
        )
    }

    /// 로그인한 계정을 저장하거나 갱신한다.
    ///
    /// 조회 기준은 이메일이 아니라 `sub` 다. 이메일은 조직 안에서 바뀔 수 있다.
    private func upsertUser(
        request: Request,
        googleSubject: String,
        email: String,
        name: String,
        avatarURL: String?
    ) async throws -> User {
        let config = request.application.alleyConfig

        if let existing = try await User.query(on: request.db)
            .filter(\.$googleSubject == googleSubject)
            .first()
        {
            existing.email = email
            existing.name = name
            existing.avatarURL = avatarURL
            existing.lastLoginAt = Date()
            try await existing.save(on: request.db)
            return existing
        }

        // 최초 로그인. 설정에 적힌 계정만 관리자로 시작하고 나머지는 일반 사용자다.
        let isInitialAdmin = config.store.initialAdminEmails.contains(email)
        let user = User(
            googleSubject: googleSubject,
            email: email,
            name: name,
            avatarURL: avatarURL,
            role: isInitialAdmin ? .admin : .user
        )
        user.lastLoginAt = Date()
        try await user.save(on: request.db)
        return user
    }
}

// MARK: - 페이로드

// 타입 자체는 AlleyShared 에 있다. 스토어 앱이 같은 것을 디코딩한다.
extension TokenExchangeRequest: Content {}
extension TokenExchangeResponse: Content {}
extension UserDTO: Content {}
