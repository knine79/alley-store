import AlleyShared
import Fluent
import Foundation
import Vapor

/// 알림 대상의 등록·조회·삭제.
///
/// 앱에 붙는 대상은 **앱을 관리하는 사람**이, 전역 대상은 **관리자**가 다룬다.
/// 웹훅 URL 은 그 채널에 글을 쓸 수 있는 자격증명이라 등록할 때만 받고 다시
/// 내려주지 않는다.
public struct NotificationController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let authenticated = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apiRoot.pathComponents)

        let ofApp = authenticated.grouped("apps", ":appID", "notification-targets")
        ofApp.get(use: listForApp)
        ofApp.post(use: createForApp)
        ofApp.delete(":targetID", use: removeFromApp)

        let global = authenticated.grouped("admin", "notification-targets")
        global.get(use: listGlobal)
        global.post(use: createGlobal)
        global.delete(":targetID", use: removeGlobal)
    }

    // MARK: - 앱별

    @Sendable
    func listForApp(request: Request) async throws -> [NotificationTargetDTO] {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        return try await NotificationTarget.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .sort(\.$name)
            .all()
            .map { try $0.toDTO() }
    }

    @Sendable
    func createForApp(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let payload = try request.content.decode(CreateNotificationTargetRequest.self)
        let target = try await NotificationTargets.create(
            payload,
            appID: try app.requireID(),
            by: user,
            on: request.db,
            logger: request.logger
        )

        let response = Response(status: .created)
        try response.content.encode(try target.toDTO())
        return response
    }

    @Sendable
    func removeFromApp(request: Request) async throws -> HTTPStatus {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        try await NotificationTargets.remove(
            try request.targetID(),
            appID: try app.requireID(),
            on: request.db
        )
        return .noContent
    }

    // MARK: - 전역

    @Sendable
    func listGlobal(request: Request) async throws -> [NotificationTargetDTO] {
        _ = try request.requireAdmin()
        return try await NotificationTarget.query(on: request.db)
            .filter(\.$app.$id == nil)
            .sort(\.$name)
            .all()
            .map { try $0.toDTO() }
    }

    @Sendable
    func createGlobal(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let payload = try request.content.decode(CreateNotificationTargetRequest.self)
        let target = try await NotificationTargets.create(
            payload,
            appID: nil,
            by: admin,
            on: request.db,
            logger: request.logger
        )

        let response = Response(status: .created)
        try response.content.encode(try target.toDTO())
        return response
    }

    @Sendable
    func removeGlobal(request: Request) async throws -> HTTPStatus {
        _ = try request.requireAdmin()
        try await NotificationTargets.remove(
            try request.targetID(),
            appID: nil,
            on: request.db
        )
        return .noContent
    }
}

/// 알림 대상 등록의 규칙.
enum NotificationTargets {
    static func create(
        _ payload: CreateNotificationTargetRequest,
        appID: UUID?,
        by user: User,
        on database: any Database,
        logger: Logger
    ) async throws -> NotificationTarget {
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = payload.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "이름이 비어 있습니다. 어느 채널인지 알아볼 이름을 적으세요.")
        }
        try validate(endpoint: endpoint, kind: payload.kind)

        let target = NotificationTarget(
            appID: appID,
            kind: payload.kind,
            name: name,
            endpoint: endpoint,
            createdByID: try user.requireID()
        )
        try await target.save(on: database)

        // 주소 자체는 남기지 않는다. 로그가 자격증명 저장소가 되면 안 된다.
        logger.notice("알림 대상 추가 [\(payload.kind.rawValue), 이름: \(name), 등록: \(user.email)]")
        return target
    }

    /// 주소가 그 채널의 것으로 보이는지.
    ///
    /// 오타 하나로 알림이 조용히 사라지는 것을 저장 시점에 막는다. 실제로 받는지는
    /// 보내봐야 알지만, 형식이 틀린 것은 지금 걸러낼 수 있다.
    static func validate(endpoint: String, kind: NotificationChannelKind) throws {
        // DM 은 관리자가 만드는 대상이 아니다. 받는 사람을 서버가 알고 그때그때
        // 보내는 것이라 등록할 자리가 없다 (`Notifier.notify(person:)`).
        guard kind != .slackDirectMessage else {
            throw Abort(.badRequest, reason: "Slack DM 은 알림 대상으로 등록할 수 없습니다.")
        }

        // 메일은 주소지 웹훅이 아니다. 아래 https 검사를 지날 수 없다.
        if kind == .email {
            try validate(emailAddress: endpoint)
            return
        }

        guard let components = URLComponents(string: endpoint),
              components.scheme?.lowercased() == "https",
              let host = components.host
        else {
            throw Abort(.badRequest, reason: "웹훅 주소는 https 로 시작하는 절대 주소여야 합니다.")
        }

        switch kind {
        case .slack:
            guard host.hasSuffix("slack.com") else {
                throw Abort(
                    .badRequest,
                    reason: "Slack 웹훅 주소가 아닙니다. hooks.slack.com 으로 시작해야 합니다."
                )
            }
        case .slackDirectMessage, .email:
            // 위에서 갈라 보냈다. 갈래가 늘면 컴파일러가 여기를 다시 물어본다.
            break
        }
    }

    /// 메일 주소로 보이는지만 본다.
    ///
    /// **진짜인지는 보내봐야 안다.** 형식이 맞아도 없는 주소일 수 있고, 형식으로
    /// 거를 수 있는 것은 오타 중 일부뿐이다. 그래서 `@` 하나와 점 하나만 본다.
    /// 더 까다롭게 굴면 실제로 쓰는 주소를 거절하게 된다.
    static func validate(emailAddress: String) throws {
        let trimmed = emailAddress.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !trimmed.contains(" ")
        else {
            throw Abort(.badRequest, reason: "메일 주소 형식이 아닙니다: \(emailAddress)")
        }
    }

    static func remove(_ targetID: UUID, appID: UUID?, on database: any Database) async throws {
        let query = NotificationTarget.query(on: database).filter(\.$id == targetID)
        // 앱의 것을 지우려다 전역 대상을 지우는 일이 없게 범위를 함께 건다.
        if let appID {
            query.filter(\.$app.$id == appID)
        } else {
            query.filter(\.$app.$id == nil)
        }

        guard let target = try await query.first() else {
            throw Abort(.notFound, reason: "알림 대상을 찾을 수 없습니다.")
        }
        try await target.delete(on: database)
    }
}

extension Request {
    func targetID() throws -> UUID {
        guard let id = parameters.get("targetID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "알림 대상 ID 형식이 올바르지 않습니다.")
        }
        return id
    }
}

extension NotificationTargetDTO: Content {}
extension CreateNotificationTargetRequest: Content {}
