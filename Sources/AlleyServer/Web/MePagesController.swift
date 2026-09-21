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
        // 화면이 칸을 그리지 않는 상태다. 여기까지 오는 길은 폼을 손으로 만드는
        // 것뿐이고, 받아 봐야 켜도 아무 일이 없는 값이 저장된다.
        guard request.application.alleyConfig.slackBotToken != nil else {
            throw Abort(.conflict, reason: "Slack 봇이 연결되어 있지 않아 알림을 정할 수 없습니다.")
        }
        let values = try request.content.decode(NotificationPreferenceValues.self)

        // 체크박스는 꺼져 있으면 아예 보내지지 않는다. 값이 없으면 끈 것이다.
        user.notifySigningFailure = values.signingFailure == "on"
        user.notifyFeedback = values.feedback == "on"
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
                delivery: try await deliveryStatus(for: user, on: request),
                saved: saved
            )
        ).get()
    }

    /// DM 이 실제로 닿는지 지금 확인한다.
    ///
    /// **켜둔 뒤 처음 알림이 날 때 알게 되면 늦다.** 스토어 계정과 Slack 계정의
    /// 이메일이 다르면 못 찾는데, 그 사실은 지금까지 서버 로그에만 남았다. 고르는
    /// 자리에서 한 번 찾아보면 그 자리에서 알고 관리자에게 물을 수 있다.
    ///
    /// Slack 을 한 번 부르는 값이라 화면을 열 때마다 왕복이 생긴다. 이 화면은 자주
    /// 여는 곳이 아니라 그 대가를 받아들인다.
    private func deliveryStatus(
        for user: User,
        on request: Request
    ) async throws -> DeliveryStatus {
        guard let token = request.application.alleyConfig.slackBotToken else {
            return DeliveryStatus(
                isUsable: false,
                detail: "관리자가 Slack 봇을 연결하지 않아 알림을 받을 수 없습니다."
            )
        }

        let channel = SlackDirectMessageChannel(client: request.client, botToken: token)
        do {
            let handle = try await channel.findRecipient(email: user.email)
            return DeliveryStatus(isUsable: true, detail: "\(handle) 으로 보냅니다.")
        } catch {
            return DeliveryStatus(isUsable: false, detail: String(describing: error))
        }
    }
}

/// 내 알림 화면이 쓰는 값.
struct MyNotificationsContext: Encodable {
    var page: PageContext
    var signingFailure: Bool
    var feedback: Bool
    var delivery: DeliveryStatus
    var saved: Bool
}

/// DM 이 닿는지.
struct DeliveryStatus: Encodable {
    /// 지금 보낼 수 있나. 아니면 체크박스를 켜도 아무 일이 없다.
    var isUsable: Bool
    /// 사람에게 그대로 보여줄 한 줄.
    var detail: String
}

struct NotificationPreferenceValues: Codable {
    var signingFailure: String?
    var feedback: String?
}

extension NotificationPreferenceValues: Content {}
