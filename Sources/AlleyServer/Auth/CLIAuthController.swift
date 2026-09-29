import AlleyShared
import Fluent
import Vapor

/// CLI 를 이 계정에 연결한다 (ADR-0064).
///
/// **긴 수명 토큰을 주소에 싣지 않는다.** CLI 로 돌아가는 주소에 실리는 것은 2분
/// 사는 일회용 코드다. 90일 사는 사람 토큰을 URL 에 실으면 브라우저 기록과 시스템
/// 로그에 남는다. 스토어 앱이 세션 토큰을 받아갈 때 이미 같은 이유로 같은 구조를
/// 쓴다 (`AuthCode`).
struct CLIAuthController: RouteCollection, Sendable {
    /// 기다리는 쪽이 루프백이라 포트만 받는다. 주소를 통째로 받으면 그 값으로
    /// 아무 데나 보내는 열린 리다이렉터가 된다.
    static let portQueryItem = "port"
    /// CLI 가 만들어 보내는 무작위 값. 돌아온 것과 대조해 남이 끼어든 것을 막는다.
    static let stateQueryItem = "state"
    /// 화면에 보일 기기 이름. CLI 가 `호스트명-짧은해시` 로 지어 보낸다.
    static let deviceQueryItem = "device"

    func boot(routes: any RoutesBuilder) throws {
        // 로그인이 필요하다. 안 돼 있으면 여느 화면처럼 OIDC 로 보냈다 돌아온다.
        let pages = routes.grouped(SessionAuthenticator(), User.guardMiddleware())
        pages.get(APIPath.cliAuthorize.pathComponents, use: confirmForm)
        pages.post(APIPath.cliAuthorize.pathComponents, use: approve)

        // 교환은 CLI 가 부른다. 쿠키가 없으므로 인증을 걸지 않는다. 코드 자체가
        // 자격증명이다.
        routes.post(APIPath.cliTokenExchange.pathComponents, use: exchange)
    }

    // MARK: - 확인 화면

    @Sendable
    func confirmForm(request: Request) async throws -> View {
        let handoff = try Handoff(request)
        return try await render(handoff, error: nil, on: request)
    }

    /// 눌렀다. 일회용 코드를 만들어 CLI 로 돌려보낸다.
    @Sendable
    func approve(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let handoff = try Handoff(request)

        let (plaintext, model) = AuthCode.issue(userID: try user.requireID())
        try await model.save(on: request.db)

        request.logger.notice(
            "CLI 연결을 승인했습니다 [사람: \(user.email), 기기: \(handoff.device)]"
        )

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = handoff.port
        // **경로를 빼먹지 않는다.** 비워두면 `http://127.0.0.1:1234?code=…` 가 되고,
        // 기다리는 쪽은 `GET /?code=…` 를 볼 줄 알고 있어서 어긋난다.
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "code", value: plaintext),
            URLQueryItem(name: Self.stateQueryItem, value: handoff.state),
        ]
        return request.redirect(to: components.url!.absoluteString)
    }

    // MARK: - 코드 교환

    @Sendable
    func exchange(request: Request) async throws -> CLITokenResponse {
        let payload = try request.content.decode(CLITokenRequest.self)
        let now = Date()

        guard let code = try await AuthCode.query(on: request.db)
            .filter(\.$codeHash == AuthCode.hash(payload.code))
            .with(\.$user)
            .first()
        else {
            throw Abort(.unauthorized, reason: "코드가 유효하지 않습니다.")
        }
        guard code.isUsable(at: now) else {
            throw Abort(.unauthorized, reason: "코드가 이미 사용되었거나 만료되었습니다.")
        }

        // 먼저 소진 처리한다. 같은 코드로 두 번 받아가는 일을 막는다.
        code.consumedAt = now
        try await code.save(on: request.db)

        let user = code.user
        // 코드를 받아둔 뒤에 탈퇴 처리됐을 수 있다 (ADR-0061).
        guard user.isActive else {
            throw Abort(.unauthorized, reason: "탈퇴 처리된 계정입니다.")
        }

        let name = Self.deviceName(payload.device)
        let value = UserToken.generateToken()
        let model = UserToken(
            name: name,
            tokenHash: UserToken.hash(token: value),
            userID: try user.requireID(),
            expiresAt: now.addingTimeInterval(UserToken.lifetime)
        )
        try await model.save(on: request.db)

        request.logger.notice("CLI 토큰을 냈습니다 [사람: \(user.email), 이름: \(name)]")
        return CLITokenResponse(
            token: value,
            name: name,
            expiresAt: model.expiresAt,
            email: user.email,
            userName: user.name
        )
    }

    // MARK: - 보조

    /// CLI 가 보낸 기기 이름을 다듬는다.
    ///
    /// 화면과 목록에 그대로 나가는 값이고 CLI 가 보낸 것이라 믿을 수 없다. 길이를
    /// 자르고, 줄바꿈처럼 한 줄 목록을 깨뜨리는 것을 뺀다. 비어 있으면 이름 없는
    /// 줄이 목록에 서지 않게 대신 채운다.
    static func deviceName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "alley CLI" }
        return String(cleaned.prefix(MePagesController.maximumTokenNameLength))
    }

    /// CLI 가 넘겨준 것들. 하나라도 어긋나면 화면을 그리지 않는다.
    ///
    /// **쿼리와 폼 양쪽에서 읽는다.** 처음 들어올 때는 주소에 실려 오고, 연결을 누를
    /// 때는 화면이 숨은 칸으로 되돌려준다. 같은 값을 두 번 검사해야 폼을 손으로
    /// 만들어 다른 포트로 보내는 길이 막힌다.
    private struct Handoff: Content {
        var port: Int
        var state: String
        var device: String = ""

        init(_ request: Request) throws {
            let raw: Handoff
            do {
                raw = request.method == .POST
                    ? try request.content.decode(Handoff.self)
                    : try request.query.decode(Handoff.self)
            } catch {
                throw Abort(
                    .badRequest,
                    reason: "연결에 필요한 값이 없습니다. `alley auth login` 으로 다시 시작하세요."
                )
            }
            guard (1024...65535).contains(raw.port) else {
                throw Abort(.badRequest, reason: "기다리는 포트가 아닙니다. `alley auth login` 으로 다시 시작하세요.")
            }
            guard !raw.state.isEmpty, raw.state.count <= 128 else {
                throw Abort(.badRequest, reason: "확인 값이 없습니다. `alley auth login` 으로 다시 시작하세요.")
            }
            self.port = raw.port
            self.state = raw.state
            self.device = CLIAuthController.deviceName(raw.device)
        }

        /// `Content` 를 따르느라 필요한 자리. 직접 만들지 않는다.
        init(port: Int, state: String, device: String) {
            self.port = port
            self.state = state
            self.device = device
        }
    }

    private func render(_ handoff: Handoff, error: String?, on request: Request) async throws -> View {
        let user = try request.requireUser()
        return try await request.view.render(
            "cli-authorize",
            CLIAuthorizeContext(
                page: try await request.pageContext(title: "기기 연결"),
                device: handoff.device,
                port: handoff.port,
                state: handoff.state,
                email: user.email,
                userName: user.name,
                lifetimeDays: Int(UserToken.lifetime / 86_400),
                error: error
            )
        ).get()
    }
}

/// CLI 가 코드를 보내며 자기 이름을 함께 준다.
struct CLITokenRequest: Content {
    var code: String
    var device: String
}

/// 교환 결과. 원문은 이 응답에만 있다.
struct CLITokenResponse: Content {
    var token: String
    var name: String
    var expiresAt: Date
    var email: String
    var userName: String
}

struct CLIAuthorizeContext: Encodable {
    var page: PageContext
    var device: String
    var port: Int
    var state: String
    var email: String
    var userName: String
    var lifetimeDays: Int
    var error: String?
}
