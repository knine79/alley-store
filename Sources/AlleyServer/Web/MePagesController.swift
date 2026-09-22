import AlleyShared
import Fluent
import Vapor

/// 로그인한 사람이 자기 것만 바꾸는 화면.
///
/// **관리 화면과 나눈다.** 관리자가 남의 알림 설정을 대신 켜고 끌 이유가 없다.
/// 역할 관리와 달리 이것은 그 사람의 취향이고, 잘못 정해도 다른 사람에게 영향이
/// 없다.
struct MePagesController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("me")

        pages.get("notifications", use: notificationsForm)
        pages.post("notifications", use: submitNotifications)
        pages.get("tokens", use: tokenList)
        pages.post("tokens", use: issueToken)
        pages.post("tokens", ":tokenID", "revoke", use: revokeToken)
    }

    // MARK: - 내 토큰 (ADR-0060)

    @Sendable
    func tokenList(request: Request) async throws -> View {
        try await renderTokens(issued: nil, error: nil, on: request)
    }

    /// 토큰을 발급한다. 원문은 이 응답에만 있다.
    @Sendable
    func issueToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let values = try request.content.decode(TokenFormValues.self)
        let name = values.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            let view = try await renderTokens(
                issued: nil,
                error: "어디에 넣을 토큰인지 적어주세요. 나중에 무엇을 끊을지 고를 때 이 이름만 보입니다.",
                on: request
            )
            return htmlResponse(view, status: .badRequest)
        }

        let value = UserToken.generateToken()
        let token = UserToken(
            name: name,
            tokenHash: UserToken.hash(token: value),
            userID: try user.requireID(),
            expiresAt: Date().addingTimeInterval(UserToken.lifetime)
        )
        try await token.save(on: request.db)
        request.logger.notice("사람 토큰 발급 [사람: \(user.email), 이름: \(name)]")

        // 리다이렉트하지 않는다. 원문을 한 번만 보여주는 화면이라 새로고침으로
        // 날아가면 다시 발급받는 수밖에 없다.
        let view = try await renderTokens(issued: value, error: nil, on: request)
        return htmlResponse(view, status: .ok)
    }

    @Sendable
    func revokeToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        guard let raw = request.parameters.get("tokenID"),
              let tokenID = UUID(uuidString: raw)
        else {
            throw Abort(.badRequest, reason: "토큰을 알 수 없습니다.")
        }

        // 남의 토큰을 끊지 못하게 사람으로도 거른다. 주소를 손으로 만들면 남의
        // 토큰 id 를 넣을 수 있다.
        guard let token = try await UserToken.query(on: request.db)
            .filter(\.$id == tokenID)
            .filter(\.$user.$id == user.requireID())
            .first()
        else {
            throw Abort(.notFound, reason: "그런 토큰이 없습니다.")
        }

        if token.revokedAt == nil {
            token.revokedAt = Date()
            try await token.save(on: request.db)
            request.logger.notice("사람 토큰 폐기 [사람: \(user.email), 이름: \(token.name)]")
        }
        return request.redirect(to: "/me/tokens")
    }

    private func renderTokens(
        issued: String?,
        error: String?,
        on request: Request
    ) async throws -> View {
        let user = try request.requireUser()
        let tokens = try await UserToken.query(on: request.db)
            .filter(\.$user.$id == user.requireID())
            .sort(\.$createdAt, .descending)
            .all()

        return try await request.view.render(
            "me-tokens",
            MyTokensContext(
                page: try await request.pageContext(title: "내 토큰"),
                tokens: try tokens.map(TokenRow.init),
                issued: issued,
                error: error
            )
        ).get()
    }

    private func htmlResponse(_ view: View, status: HTTPStatus) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
    }

    @Sendable
    func notificationsForm(request: Request) async throws -> View {
        try await render(saved: false, on: request)
    }

    @Sendable
    func submitNotifications(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let values = try request.content.decode(NotificationPreferenceValues.self)

        // 체크박스는 꺼져 있으면 아예 보내지지 않는다. 값이 없으면 끈 것이다.
        user.notifySigningFailure = values.signingFailure == "on"
        user.notifyFeedback = values.feedback == "on"

        // **비활성 칸은 폼에서 오지 않는다.** 지금 쓸 수 없는 수단은 회색으로 두는데,
        // 그 값을 "껐다" 로 읽으면 Slack 이 잠깐 안 되는 사이에 저장을 누른 사람의
        // 선택이 조용히 지워진다. 그래서 쓸 수 있는 것만 폼의 값으로 갈아끼우고,
        // 나머지는 저장돼 있던 대로 둔다.
        let usable = Set(PersonalDelivery.configured(on: request))
        let sent = Set(
            (values.via ?? []).compactMap(NotificationChannelKind.init(rawValue:))
        )
        user.notifyVia = user.notifyVia.subtracting(usable).union(sent.intersection(usable))
        try await user.save(on: request.db)

        // 리다이렉트하지 않는다. 바꾼 값이 그대로 보이는 화면을 다시 그리고,
        // 저장됐다는 것만 위에 띄운다.
        let view = try await render(saved: true, on: request)
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
    }

    private func render(saved: Bool, on request: Request) async throws -> View {
        let user = try request.requireUser()
        return try await request.view.render(
            "me-notifications",
            MyNotificationsContext(
                page: try await request.pageContext(title: "내 알림"),
                signingFailure: user.notifySigningFailure,
                feedback: user.notifyFeedback,
                ways: await PersonalDelivery.all(for: user, on: request),
                saved: saved
            )
        ).get()
    }
}

/// 나에게 오는 알림을 받을 수 있는 방법 하나.
struct PersonalDelivery: Encodable {
    /// `NotificationChannelKind` 의 rawValue. 체크박스 값으로 그대로 쓴다.
    var value: String
    /// 사람에게 보여줄 이름.
    var label: String
    /// 어디로 가는지 한 줄. 지금 쓸 수 없으면 무엇이 갖춰져야 하는지.
    var detail: String
    /// 지금 보낼 수 있나. 아니면 칸을 회색으로 둔다.
    var isUsable: Bool
    /// 내가 골라둔 것인가.
    var isChosen: Bool

    /// 이 스토어가 갖춘 개인 알림 수단들. 설정만 보고 닿는지는 보지 않는다.
    static func configured(on request: Request) -> [NotificationChannelKind] {
        let config = request.application.alleyConfig
        var kinds: [NotificationChannelKind] = []
        if config.slackBotToken != nil { kinds.append(.slackDirectMessage) }
        if config.smtp != nil { kinds.append(.email) }
        return kinds
    }

    /// 화면에 그릴 수단들. **쓸 수 없는 것도 그린다.**
    ///
    /// 목록에서 빼버리면 왜 메일 하나뿐인지 알 수 없고, 관리자가 Slack 을 붙이면
    /// 생긴다는 것도 모른다. 회색으로 두고 무엇이 갖춰져야 하는지를 한 줄 적는다.
    ///
    /// Slack 은 한 번 불러 닿는지 본다. 스토어 계정과 Slack 계정의 이메일이 다르면
    /// 못 찾는데, 그 사실을 처음 알림이 날 때 알게 되면 늦다. 이 화면은 자주 여는
    /// 곳이 아니라 왕복 한 번을 받아들인다. 메일은 부르지 않는다 - 보내 보기 전에는
    /// 주소가 살아 있는지 알 수 없고, 알아보려고 한 통 보낼 수는 없다.
    static func all(for user: User, on request: Request) async -> [PersonalDelivery] {
        var ways: [PersonalDelivery] = []

        if let token = request.application.alleyConfig.slackBotToken {
            let channel = SlackDirectMessageChannel(client: request.client, botToken: token)
            // **어떻게 실패했는지는 적지 않는다.** 이 화면을 보는 사람은 Slack 을
            // 부른 적이 없다. `invalid_auth` 같은 코드를 보여줘도 할 수 있는 것이
            // 없고, 할 수 있는 것이 있는 경우(이메일이 다름)만 그것을 적는다.
            switch await recipient(of: channel, email: user.email) {
            case .found(let handle):
                ways.append(
                    PersonalDelivery(
                        kind: .slackDirectMessage,
                        detail: "\(handle) 으로 보냅니다.",
                        isUsable: true
                    )
                )
            case .noSuchUser:
                ways.append(
                    PersonalDelivery(
                        kind: .slackDirectMessage,
                        detail: "이 계정의 이메일로 Slack 사용자를 찾지 못했습니다.",
                        isUsable: false
                    )
                )
            case .unavailable:
                ways.append(.unavailableSlack)
            }
        } else {
            ways.append(.unavailableSlack)
        }

        if request.application.alleyConfig.smtp != nil {
            ways.append(
                PersonalDelivery(
                    kind: .email,
                    detail: "\(user.email) 으로 보냅니다.",
                    isUsable: true
                )
            )
        } else {
            ways.append(
                PersonalDelivery(
                    kind: .email,
                    detail: "관리자가 메일을 연결하면 고를 수 있습니다.",
                    isUsable: false
                )
            )
        }

        return mark(chosenIn: ways, by: user)
    }

    /// **화면이 실제로 가는 곳을 보여준다.**
    ///
    /// 고른 것이 지금 쓸 수 없으면 알림은 쓸 수 있는 것 하나로 간다
    /// (`Notifier.notify(person:)`). 그때 화면이 저장된 값만 그리면, 체크가 하나도
    /// 없는데 메일은 오는 상태가 된다. 되짚어 가는 곳에 체크를 그려서 보이는 것과
    /// 가는 곳을 맞춘다. 그 상태로 저장을 누르면 그것이 그대로 저장된다.
    private static func mark(chosenIn ways: [PersonalDelivery], by user: User) -> [PersonalDelivery] {
        let usable = ways.filter(\.isUsable).map(\.kind)
        var effective = Set(usable.filter(user.notifyVia.contains))
        if effective.isEmpty, let first = usable.first {
            effective = [first]
        }
        return ways.map { way in
            var marked = way
            marked.isChosen = effective.contains(way.kind)
            return marked
        }
    }

    private static var unavailableSlack: PersonalDelivery {
        PersonalDelivery(
            kind: .slackDirectMessage,
            detail: "관리자가 Slack 봇을 연결하면 고를 수 있습니다.",
            isUsable: false
        )
    }

    /// Slack 에서 이 사람을 찾은 결과.
    ///
    /// 갈래를 셋으로 나누는 이유는 **할 수 있는 일이 다르기 때문이다.** 계정을 못
    /// 찾은 것은 내 이메일 이야기라 관리자에게 알릴 수 있고, 나머지는 스토어 설정
    /// 이야기라 내가 할 것이 없다.
    private enum Recipient {
        case found(String)
        case noSuchUser
        case unavailable
    }

    private static func recipient(
        of channel: SlackDirectMessageChannel,
        email: String
    ) async -> Recipient {
        do {
            return .found(try await channel.findRecipient(email: email))
        } catch SlackDirectMessageChannel.ChannelError.noSuchUser {
            return .noSuchUser
        } catch {
            return .unavailable
        }
    }

    /// 무엇을 고른 상태인지는 `mark(chosenIn:by:)` 가 나중에 채운다. 되짚어 가는
    /// 곳까지 보려면 목록이 다 모인 뒤라야 알 수 있다.
    var kind: NotificationChannelKind {
        NotificationChannelKind(rawValue: value) ?? .email
    }

    init(kind: NotificationChannelKind, detail: String, isUsable: Bool) {
        self.value = kind.rawValue
        self.label = kind.displayName
        self.detail = detail
        self.isUsable = isUsable
        self.isChosen = false
    }
}

/// 내 알림 화면이 쓰는 값.
struct MyNotificationsContext: Encodable {
    var page: PageContext
    var signingFailure: Bool
    var feedback: Bool
    /// 받는 방법들. 쓸 수 없는 것도 회색으로 들어 있다.
    var ways: [PersonalDelivery]
    var saved: Bool
}

struct NotificationPreferenceValues: Codable {
    var signingFailure: String?
    var feedback: String?
    /// 체크박스 여럿이라 값도 여럿 온다. 하나도 안 고르면 오지 않는다.
    var via: [String]?
}

extension NotificationPreferenceValues: Content {}

/// 내 토큰 화면이 쓰는 값 (ADR-0060).
struct MyTokensContext: Encodable {
    var page: PageContext
    var tokens: [TokenRow]
    /// 방금 발급한 토큰의 원문. 이 응답에만 있다.
    var issued: String?
    var error: String?
}

/// 목록에 뜨는 토큰 한 줄.
struct TokenRow: Encodable {
    var id: String
    var name: String
    var createdAt: DisplayDate
    var expiresAt: DisplayDate
    var lastUsedAt: DisplayDate?
    /// 지금 쓸 수 있나. 폐기됐거나 만료됐으면 false.
    var isUsable: Bool
    /// 왜 못 쓰나. 쓸 수 있으면 nil.
    ///
    /// 만료와 폐기를 가려서 적는다. 만료는 스스로 고칠 수 있고 폐기는 끊은 것이라
    /// 사람이 할 일이 다르다.
    var blocked: String?

    init(token: UserToken) throws {
        self.id = try token.requireID().uuidString
        self.name = token.name
        self.createdAt = DateStyle.minute.display(from: token.createdAt ?? Date())
        self.expiresAt = DateStyle.minute.display(from: token.expiresAt)
        self.lastUsedAt = token.lastUsedAt.map { DateStyle.minute.display(from: $0) }
        self.isUsable = token.isUsable()
        if token.revokedAt != nil {
            self.blocked = "폐기함"
        } else if token.expiresAt <= Date() {
            self.blocked = "만료됨"
        } else {
            self.blocked = nil
        }
    }
}

struct TokenFormValues: Codable {
    var name: String
}

extension TokenFormValues: Content {}
