import AlleyShared
import Fluent
import Vapor

/// 운영 알림을 어디로 보낼지 정하는 화면.
///
/// **여기서 정하는 것은 한 갈래뿐이다.** 워커가 조용해지거나 인증서가 만료될 때
/// 가는 알림이고, 앱 하나가 아니라 스토어 전체가 멈추는 종류라 관리자가 받는다.
///
/// 앱 채널(앱 상세 > 알림)과 개인 알림(내 알림)은 각자 다른 화면에 있다. 셋은
/// 받는 사람도 정하는 사람도 다르다. 한 화면에 모으면 저장 버튼 하나가 세 가지
/// 뜻을 갖는다.
///
/// 전역 알림 대상은 지금까지 API 로만 만들 수 있었다. 화면이 없으니 아무도 만들어
/// 두지 않았고, 그래서 워커가 죽어도 아무 데도 가지 않았다.
struct AdminNotificationPagesController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("admin", "notifications")

        pages.get(use: page)
        pages.post("target", use: submitTarget)
        pages.post("targets", use: addTarget)
        pages.post("targets", ":targetID", "remove", use: removeTarget)
    }

    @Sendable
    func page(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        return try await render(error: nil, on: request)
    }

    /// 채널이냐 관리자 DM 이냐.
    @Sendable
    func submitTarget(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let values = try request.content.decode(OperationalTargetValues.self)
        guard let target = OperationalAlertTarget(rawValue: values.target ?? "") else {
            throw Abort(.badRequest, reason: "알 수 없는 값입니다: \(values.target ?? "")")
        }

        let settings = try await request.storeSettings()
        settings.operationalAlerts = target
        settings.$updatedBy.id = try admin.requireID()
        try await settings.save(on: request.db)
        request.logger.notice(
            "운영 알림 대상 변경 [\(target.rawValue), 관리자: \(admin.email)]"
        )
        return request.redirect(to: "/admin/notifications")
    }

    @Sendable
    func addTarget(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let values = try request.content.decode(NotificationTargetFormValues.self)
        do {
            _ = try await NotificationTargets.create(
                CreateNotificationTargetRequest(
                    name: values.name ?? "",
                    endpoint: values.endpoint ?? ""
                ),
                appID: nil,
                by: admin,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 주소를 잘못 적은 경우다. 목록을 그대로 두고 왜 안 되는지만 위에 띄운다.
            let view = try await render(error: abort.reason, on: request)
            let response = Response(status: abort.status)
            response.headers.contentType = .html
            response.body = .init(buffer: view.data)
            return response
        }
        return request.redirect(to: "/admin/notifications")
    }

    @Sendable
    func removeTarget(request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        guard let targetID = request.parameters.get("targetID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "대상 ID 형식이 올바르지 않습니다.")
        }
        try await NotificationTargets.remove(targetID, appID: nil, on: request.db)
        return request.redirect(to: "/admin/notifications")
    }

    private func render(error: String?, on request: Request) async throws -> View {
        let settings = try await request.storeSettings()
        let targets = try await NotificationTarget.query(on: request.db)
            .filter(\.$app.$id == nil)
            .sort(\.$name)
            .all()
            .map { try $0.toDTO() }
        let adminCount = try await User.query(on: request.db)
            .filter(\.$role == .admin)
            .count()

        return try await request.view.render(
            "admin-notifications",
            AdminNotificationsContext(
                page: try await request.pageContext(adminTab: .notifications),
                target: settings.operationalAlerts.rawValue,
                targets: targets,
                adminCount: adminCount,
                // 봇이 없으면 관리자 DM 을 골라도 아무 데도 가지 않는다. 고르기
                // 전에 알려야 한다.
                isBotConfigured: request.application.alleyConfig.slackBotToken != nil,
                error: error
            )
        ).get()
    }
}

struct AdminNotificationsContext: Encodable {
    var page: PageContext
    /// 지금 고른 값. `OperationalAlertTarget` 의 rawValue.
    var target: String
    /// 등록된 전역 채널들.
    var targets: [NotificationTargetDTO]
    /// DM 을 고르면 몇 명에게 가는지.
    var adminCount: Int
    /// 봇 토큰이 있나. 없으면 DM 을 골라도 가지 않는다.
    var isBotConfigured: Bool
    var error: String?
}

struct OperationalTargetValues: Codable {
    var target: String?
}

extension OperationalTargetValues: Content {}
