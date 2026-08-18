import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리자 전용 경로. 스토어 설정과 사용자 역할.
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

    /// 보낸 항목만 바꾼다.
    ///
    /// 화면에서 한 칸만 고쳤는데 안 보낸 항목이 기본값으로 덮이면 곤란하다.
    /// 그래서 요청 타입의 모든 항목이 옵셔널이고, nil 은 "건드리지 말라"는 뜻이다.
    @Sendable
    func updateSettings(request: Request) async throws -> StoreSettingsDTO {
        let admin = try request.requireAdmin()
        let payload = try request.content.decode(UpdateStoreSettingsRequest.self)
        let settings = try await request.storeSettings()

        if let storeName = payload.storeName {
            let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "스토어 이름은 비울 수 없습니다.")
            }
            settings.storeName = trimmed
        }

        // 빈 문자열은 "지우기"로 본다. 항목을 안 보낸 것과 구분된다.
        if let logoURL = payload.logoURL {
            settings.logoURL = logoURL.isEmpty ? nil : logoURL
        }
        if let accentColor = payload.accentColor {
            settings.accentColor = accentColor.isEmpty ? nil : accentColor
        }
        if let prefix = payload.bundleIDPrefix {
            settings.bundleIDPrefix = prefix.isEmpty ? nil : prefix
        }
        if let enforce = payload.enforceBundleIDPrefix {
            settings.enforceBundleIDPrefix = enforce
        }

        if let domains = payload.allowedEmailDomains {
            settings.allowedEmailDomains = try normalize(
                domains: domains,
                confirmed: payload.confirmOpenToAnyDomain == true
            )
        }

        settings.$updatedBy.id = try admin.requireID()
        try await settings.save(on: request.db)

        // 로그인 문이 얼마나 열려 있는지는 사고가 났을 때 가장 먼저 확인할 값이다.
        // 누가 언제 무엇으로 바꿨는지 남긴다.
        request.logger.notice(
            "스토어 설정 변경 [관리자: \(admin.email), 허용 도메인: \(settings.allowedEmailDomains)]"
        )
        return settings.toDTO()
    }

    /// 도메인 목록을 정규화하고, 비우는 경우에는 확인을 요구한다.
    ///
    /// 목록이 비면 조직 밖 계정도 전부 로그인할 수 있다. 예전에는 서버를 다시 배포해야
    /// 바꿀 수 있던 값이라 그 자체가 장벽이었는데, 화면에서 바꾸게 되면서 그 장벽이
    /// 사라졌다. 오타 한 번으로 그렇게 되는 것과, 그러겠다고 한 번 더 말하는 것은 다르다.
    private func normalize(domains: [String], confirmed: Bool) throws -> [String] {
        let cleaned = domains
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        if cleaned.isEmpty, !confirmed {
            throw Abort(
                .badRequest,
                reason: """
                    허용 도메인을 비우면 어떤 계정이든 로그인할 수 있습니다. \
                    정말 그렇게 하려면 confirmOpenToAnyDomain 을 함께 보내세요.
                    """
            )
        }

        // 중복을 없애되 관리자가 넣은 순서는 유지한다. 화면에서 순서가 뒤집히면 헷갈린다.
        var seen = Set<String>()
        return cleaned.filter { seen.insert($0).inserted }
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
        guard let targetID = request.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "사용자 ID 형식이 올바르지 않습니다.")
        }
        guard let target = try await User.find(targetID, on: request.db) else {
            throw Abort(.notFound, reason: "사용자를 찾을 수 없습니다.")
        }

        let payload = try request.content.decode(UpdateUserRoleRequest.self)

        // 마지막 관리자가 스스로 강등하면 아무도 설정을 못 바꾸게 된다.
        // 남은 관리자가 없어지는 변경만 막는다.
        if target.role.canAdminister, !payload.role.canAdminister {
            let remaining = try await User.query(on: request.db)
                .filter(\.$role == .admin)
                .filter(\.$id != targetID)
                .count()
            guard remaining > 0 else {
                throw Abort(.badRequest, reason: "마지막 관리자의 역할은 바꿀 수 없습니다. 다른 관리자를 먼저 지정하세요.")
            }
        }

        let previous = target.role
        target.role = payload.role
        try await target.save(on: request.db)

        request.logger.notice(
            "역할 변경 [대상: \(target.email), \(previous.rawValue) → \(payload.role.rawValue), 관리자: \(admin.email)]"
        )
        return try target.toDTO()
    }
}

extension StoreSettingsDTO: Content {}
extension UpdateStoreSettingsRequest: Content {}
extension UpdateUserRoleRequest: Content {}
