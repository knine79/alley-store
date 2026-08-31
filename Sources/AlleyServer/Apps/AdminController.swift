import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리자 전용 경로. 스토어 설정과 사용자 역할.
///
/// 실제 규칙은 `AdminOperations` 에 있다. 웹 콘솔의 관리자 화면이 같은 코드를 지난다.
public struct AdminController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let admin = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.adminRoot.pathComponents)

        admin.get("settings", use: readSettings)
        admin.patch("settings", use: updateSettings)
        admin.get("users", use: listUsers)
        admin.patch("users", ":userID", use: updateUserRole)
    }

    // MARK: - 스토어 설정

    @Sendable
    func readSettings(request: Request) async throws -> StoreSettingsDTO {
        _ = try request.requireAdmin()
        return try await request.storeSettings().toDTO()
    }

    @Sendable
    func updateSettings(request: Request) async throws -> StoreSettingsDTO {
        let admin = try request.requireAdmin()
        let payload = try request.content.decode(UpdateStoreSettingsRequest.self)
        let settings = try await request.storeSettings()

        try await AdminOperations.updateSettings(
            payload,
            of: settings,
            by: admin,
            on: request.db,
            logger: request.logger
        )
        return settings.toDTO()
    }

    // MARK: - 사용자 역할

    @Sendable
    func listUsers(request: Request) async throws -> [UserDTO] {
        _ = try request.requireAdmin()
        return try await User.query(on: request.db)
            .sort(\.$email)
            .all()
            .map { try $0.toDTO() }
    }

    @Sendable
    func updateUserRole(request: Request) async throws -> UserDTO {
        let admin = try request.requireAdmin()
        let target = try await request.findUser()
        let payload = try request.content.decode(UpdateUserRoleRequest.self)

        try await AdminOperations.changeRole(
            of: target,
            to: payload.role,
            by: admin,
            on: request.db,
            logger: request.logger
        )
        return try target.toDTO()
    }
}

extension Request {
    /// 경로 파라미터의 사용자를 찾는다. 없으면 404.
    func findUser() async throws -> User {
        guard let id = parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "사용자 ID 형식이 올바르지 않습니다.")
        }
        guard let user = try await User.find(id, on: db) else {
            throw Abort(.notFound, reason: "사용자를 찾을 수 없습니다.")
        }
        return user
    }
}

extension StoreSettingsDTO: Content {}
extension UpdateStoreSettingsRequest: Content {}
extension UpdateUserRoleRequest: Content {}
