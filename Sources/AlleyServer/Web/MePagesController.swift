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
    }

    @Sendable
    func notificationsForm(request: Request) async throws -> View {
        try await render(saved: false, on: request)
    }

    @Sendable
    func submitNotifications(request: Request) async throws -> Response {
        let user = try request.requireUser()
        // **여기서는 설정만 본다.** 닿는지까지 보려면 Slack 을 불러야 하는데, 그 왕복이
        // 실패하면 체크박스를 끄지도 못한다. 스토어가 수단을 하나도 갖추지 않은
        // 것과 내 계정을 못 찾는 것은 다른 일이다.
        let ways = PersonalDelivery.configured(on: request)
        // 화면이 칸을 그리지 않는 상태다. 여기까지 오는 길은 폼을 손으로 만드는
        // 것뿐이고, 받아 봐야 켜도 아무 일이 없는 값이 저장된다.
        guard !ways.isEmpty else {
            throw Abort(.conflict, reason: "받을 방법이 없어 알림을 정할 수 없습니다.")
        }
        let values = try request.content.decode(NotificationPreferenceValues.self)

        // 체크박스는 꺼져 있으면 아예 보내지지 않는다. 값이 없으면 끈 것이다.
        user.notifySigningFailure = values.signingFailure == "on"
        user.notifyFeedback = values.feedback == "on"
        // 받는 방법은 고를 것이 둘일 때만 폼에 선다. 하나뿐이면 값이 오지 않고,
        // 그때는 지금 값을 그대로 둔다. 어차피 보낼 때 있는 것으로 간다.
        if let via = values.via.flatMap(NotificationChannelKind.init(rawValue:)) {
            guard ways.contains(via) else {
                throw Abort(.conflict, reason: "이 스토어가 갖추지 않은 방법입니다: \(via.displayName)")
            }
            user.notifyVia = via
        }
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
        let all = await PersonalDelivery.all(for: user, on: request)
        let usable = all.filter(\.isUsable)

        return try await request.view.render(
            "me-notifications",
            MyNotificationsContext(
                page: try await request.pageContext(title: "내 알림"),
                signingFailure: user.notifySigningFailure,
                feedback: user.notifyFeedback,
                ways: usable,
                // 고른 값이 아니라 **실제로 갈 곳**을 표시한다. 고른 수단이 스토어에서
                // 빠지면 다른 것으로 가는데 (`Notifier.notify(person:)`), 화면이 고른
                // 값을 그대로 보여주면 오지도 않는 곳을 받는 곳이라고 적게 된다.
                chosen: (usable.first { $0.kind == user.notifyVia } ?? usable.first)?.value ?? "",
                blocked: all.filter { !$0.isUsable },
                saved: saved
            )
        ).get()
    }
}

/// 나에게 오는 알림을 받을 수 있는 방법 하나.
struct PersonalDelivery: Encodable {
    /// `NotificationChannelKind` 의 rawValue. 라디오 값으로 그대로 쓴다.
    var value: String
    /// 사람에게 보여줄 이름.
    var label: String
    /// 어디로 가는지 한 줄. 갈 수 없으면 왜 못 가는지.
    var detail: String
    /// 지금 보낼 수 있나. 아니면 골라도 아무 일이 없다.
    var isUsable: Bool

    var kind: NotificationChannelKind {
        NotificationChannelKind(rawValue: value) ?? .email
    }

    /// 이 스토어가 갖춘 개인 알림 수단들. 설정만 보고 닿는지는 보지 않는다.
    static func configured(on request: Request) -> [NotificationChannelKind] {
        let config = request.application.alleyConfig
        var kinds: [NotificationChannelKind] = []
        if config.slackBotToken != nil { kinds.append(.slackDirectMessage) }
        if config.smtp != nil { kinds.append(.email) }
        return kinds
    }

    /// 화면에 그릴 수단들. 갖추지 않은 것은 아예 빠진다.
    ///
    /// **고르기 전에 닿는지 보여준다.** 스토어 계정과 Slack 계정의 이메일이 다르면
    /// DM 을 찾지 못하는데, 그 사실을 처음 알림이 날 때 알게 되면 늦다. 그때는
    /// 알림이 안 온 것과 실패가 없는 것이 겉으로 같다.
    ///
    /// Slack 을 한 번 부르는 값이라 화면을 열 때마다 왕복이 생긴다. 이 화면은 자주
    /// 여는 곳이 아니라 그 대가를 받아들인다. 메일은 부르지 않는다. 보내 보기 전에는
    /// 주소가 살아 있는지 알 수 없고, 알아보려고 메일을 한 통 보낼 수는 없다.
    static func all(for user: User, on request: Request) async -> [PersonalDelivery] {
        var ways: [PersonalDelivery] = []

        if let token = request.application.alleyConfig.slackBotToken {
            let channel = SlackDirectMessageChannel(client: request.client, botToken: token)
            do {
                let handle = try await channel.findRecipient(email: user.email)
                ways.append(
                    PersonalDelivery(
                        kind: .slackDirectMessage,
                        detail: "\(handle) 으로 보냅니다.",
                        isUsable: true
                    )
                )
            } catch {
                ways.append(
                    PersonalDelivery(
                        kind: .slackDirectMessage,
                        detail: reason(error, email: user.email),
                        isUsable: false
                    )
                )
            }
        }

        if request.application.alleyConfig.smtp != nil {
            ways.append(
                PersonalDelivery(
                    kind: .email,
                    detail: "\(user.email) 으로 보냅니다.",
                    isUsable: true
                )
            )
        }

        return ways
    }

    /// 왜 못 쓰는지, **누가 고쳐야 하는지** 함께 적는다.
    ///
    /// 한 문장으로 뭉뚱그리면 봇 토큰이 잘못된 스토어에서도 "이 계정의 이메일로 못
    /// 찾았다" 고 말한다. 그러면 읽는 사람은 자기 이메일을 들여다보는데, 고칠 것은
    /// 관리자 쪽에 있다. 갈래마다 할 수 있는 일이 다르다.
    ///
    /// | 무엇 | 누가 고치나 |
    /// | --- | --- |
    /// | 그 이메일을 쓰는 Slack 계정이 없다 | 나. 메일로 받거나 관리자에게 알린다 |
    /// | Slack 이 거절했다 (토큰·권한) | 관리자 |
    /// | Slack 에 못 닿았다 | 아무도. 잠시 뒤 다시 본다 |
    static func reason(_ error: any Error, email: String) -> String {
        switch error {
        case SlackDirectMessageChannel.ChannelError.noSuchUser:
            return "\(email) 로 Slack 사용자를 찾지 못했습니다. 스토어 계정과 Slack 계정의 이메일이 다를 수 있습니다."
        case SlackDirectMessageChannel.ChannelError.rejected(_, let code):
            // 코드를 그대로 싣는다. 관리자가 Slack 쪽에서 찾아볼 때 이것이 필요하다.
            return "Slack 이 거절했습니다 (\(code)). 내 계정이 아니라 스토어의 Slack 봇 설정 문제입니다. 관리자에게 알려주세요."
        case SlackDirectMessageChannel.ChannelError.transport:
            return "Slack 에 연결하지 못했습니다. 잠시 뒤 다시 열어보세요."
        default:
            return String(describing: error)
        }
    }

    init(kind: NotificationChannelKind, detail: String, isUsable: Bool) {
        self.value = kind.rawValue
        self.label = kind.displayName
        self.detail = detail
        self.isUsable = isUsable
    }
}

/// 내 알림 화면이 쓰는 값.
struct MyNotificationsContext: Encodable {
    var page: PageContext
    var signingFailure: Bool
    var feedback: Bool
    /// 지금 받을 수 있는 방법들. 비어 있으면 정할 것이 없다.
    var ways: [PersonalDelivery]
    /// 그중 실제로 알림이 가는 것. `NotificationChannelKind` 의 rawValue.
    var chosen: String
    /// 스토어가 갖췄지만 지금 나에게는 닿지 않는 것들.
    var blocked: [PersonalDelivery]
    var saved: Bool
}

struct NotificationPreferenceValues: Codable {
    var signingFailure: String?
    var feedback: String?
    var via: String?
}

extension NotificationPreferenceValues: Content {}
