import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱별 배포 토큰의 발급·조회·폐기.
///
/// 발급은 **앱을 관리하는 사람만** 한다. 멤버는 자기 손으로 올릴 수 있지만, 사람 없이
/// 도는 자격증명을 만드는 것은 다른 무게의 일이다. 오너가 모르는 사이에 그 앱을
/// 올릴 수 있는 토큰이 생기면, 나중에 누가 만든 것인지 아무도 모른다.
public struct DeployTokenController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let managed = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apps.pathComponents)
            .grouped(":appID", "deploy-tokens")

        managed.get(use: list)
        managed.post(use: issue)
        managed.delete(":tokenID", use: revoke)

        // CLI 는 앱 ID 를 모르고 토큰만 안다. 토큰이 스스로 어느 앱의 것인지 밝힌다.
        routes
            .grouped(DeployTokenAuthenticator())
            .get(APIPath.deployApp.pathComponents, use: currentApp)
    }

    @Sendable
    func list(request: Request) async throws -> [DeployTokenDTO] {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        return try await DeployToken.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .sort(\.$name)
            .all()
            .map { try $0.toDTO() }
    }

    @Sendable
    func issue(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let payload = try request.content.decode(CreateDeployTokenRequest.self)
        let created = try await DeployTokenIssuing.issue(
            named: payload.name,
            for: app,
            by: user,
            on: request.db,
            logger: request.logger
        )

        let response = Response(status: .created)
        try response.content.encode(created)
        return response
    }

    @Sendable
    func revoke(request: Request) async throws -> DeployTokenDTO {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        guard let tokenID = request.parameters.get("tokenID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "토큰 ID 형식이 올바르지 않습니다.")
        }
        let token = try await DeployTokenIssuing.revoke(
            tokenID,
            ofApp: app,
            by: user,
            on: request.db,
            logger: request.logger
        )
        return try token.toDTO()
    }

    /// 이 토큰이 어느 앱의 것인지.
    ///
    /// CLI 가 시작할 때 한 번 부른다. 사람이 파이프라인에 엉뚱한 토큰을 넣었을 때
    /// 업로드가 절반쯤 진행된 뒤가 아니라 여기서 걸린다.
    @Sendable
    func currentApp(request: Request) async throws -> AppDTO {
        let token = try request.requireDeployToken()
        return try token.app.toDTO()
    }
}

/// 배포 토큰 발급과 폐기의 실제 규칙.
enum DeployTokenIssuing {
    static func issue(
        named name: String,
        for app: App,
        by user: User,
        on database: any Database,
        logger: Logger
    ) async throws -> CreatedDeployToken {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "토큰 이름은 비울 수 없습니다.")
        }

        // 한 앱 안에서 쓸 수 있는 토큰끼리는 이름이 겹치지 않게 한다. 화면에 나오는 것은
        // 이름과 시각뿐이라, 이름이 같으면 어느 쪽이 파이프라인에 들어 있는지 알 수 없다.
        // 발급 화면은 리다이렉트하지 않으므로 새로고침으로 폼이 다시 제출되는 경우도
        // 여기서 걸린다. 폐기한 토큰의 이름은 다시 쓸 수 있다.
        let sameName = try await DeployToken.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .filter(\.$name == trimmed)
            .all()
        guard !sameName.contains(where: \.isActive) else {
            throw Abort(.conflict, reason: "'\(trimmed)' 은 이미 쓸 수 있는 배포 토큰입니다. 새로 발급하려면 그것부터 폐기하세요.")
        }

        let value = DeployToken.generateToken()
        let token = DeployToken(
            appID: try app.requireID(),
            name: trimmed,
            tokenHash: DeployToken.hash(token: value),
            createdByID: try user.requireID()
        )
        try await token.save(on: database)

        logger.notice("배포 토큰 발급 [앱: \(app.bundleID), 이름: \(trimmed), 발급: \(user.email)]")
        return CreatedDeployToken(token: try token.toDTO(), value: value)
    }

    /// 토큰을 폐기한다.
    ///
    /// 행을 지우지 않는다. 이 토큰으로 올라간 버전이 있고, 그것이 언제 어떤 이름의
    /// 파이프라인에서 왔는지는 남아야 한다.
    @discardableResult
    static func revoke(
        _ tokenID: UUID,
        ofApp app: App,
        by user: User,
        on database: any Database,
        logger: Logger
    ) async throws -> DeployToken {
        guard let token = try await DeployToken.query(on: database)
            .filter(\.$id == tokenID)
            .filter(\.$app.$id == app.requireID())
            .first()
        else {
            throw Abort(.notFound, reason: "토큰을 찾을 수 없습니다.")
        }
        guard token.isActive else {
            throw Abort(.conflict, reason: "이미 폐기된 토큰입니다.")
        }

        token.revokedAt = Date()
        try await token.save(on: database)

        logger.notice("배포 토큰 폐기 [앱: \(app.bundleID), 이름: \(token.name), 폐기: \(user.email)]")
        return token
    }
}

extension DeployTokenDTO: Content {}
extension CreateDeployTokenRequest: Content {}
extension CreatedDeployToken: Content {}
