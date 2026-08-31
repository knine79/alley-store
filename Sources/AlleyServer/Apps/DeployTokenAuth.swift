import AlleyShared
import Fluent
import Foundation
import Vapor

/// 배포 토큰으로 온 요청에 그 토큰을 붙인다.
///
/// 사람의 세션과 나란히 선다. 사용자 인증은 `SessionAuthenticator` 가 하고, 여기서는
/// `alleyd_` 로 시작하는 토큰만 본다. 둘 다 `Authorization: Bearer` 를 쓰지만 값의
/// 생김새가 달라서 서로를 건드리지 않는다.
///
/// **막지 않는다.** 토큰이 없거나 틀려도 그냥 지나간다. 무엇이 필요한지는 각
/// 핸들러가 판단한다. 사람도 토큰도 받는 경로가 있기 때문이다.
struct DeployTokenAuthenticator: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization,
              bearer.token.hasPrefix(DeployToken.prefix)
        else {
            return try await next.respond(to: request)
        }

        let hash = DeployToken.hash(token: bearer.token)
        guard let token = try await DeployToken.query(on: request.db)
            .filter(\.$tokenHash == hash)
            .with(\.$app)
            .first()
        else {
            // 어떤 값이 왔는지는 남기지 않는다. 로그가 자격증명 저장소가 되면 안 된다.
            request.logger.warning("알 수 없는 배포 토큰으로 접근 [path: \(request.url.path)]")
            throw Abort(.unauthorized, reason: "배포 토큰이 올바르지 않습니다.")
        }
        guard token.isActive else {
            throw Abort(.unauthorized, reason: "폐기된 배포 토큰입니다. 새로 발급받으세요.")
        }

        token.lastUsedAt = Date()
        try await token.save(on: request.db)

        request.deployToken = token
        return try await next.respond(to: request)
    }
}

extension Request {
    private struct DeployTokenKey: StorageKey {
        typealias Value = DeployToken
    }

    var deployToken: DeployToken? {
        get { storage[DeployTokenKey.self] }
        set { storage[DeployTokenKey.self] = newValue }
    }

    func requireDeployToken() throws -> DeployToken {
        guard let token = deployToken else {
            throw Abort(.unauthorized, reason: "배포 토큰이 필요합니다.")
        }
        return token
    }
}

/// 앱에 버전을 올릴 자격을 가진 쪽.
///
/// 사람일 수도 있고 파이프라인일 수도 있다. 버전을 만들 때 "누가 올렸나"를 적어야
/// 하는데, 파이프라인은 사람이 아니므로 그 토큰을 발급한 사람의 이름으로 적는다.
/// 파이프라인은 사람이 아니지만 그 파이프라인에 책임이 있는 사람은 있다.
enum UploadPrincipal {
    case user(User)
    case deployToken(DeployToken)

    /// 이 버전을 올린 것으로 기록할 사용자 ID.
    var attributedUserID: UUID {
        get throws {
            switch self {
            case .user(let user): return try user.requireID()
            case .deployToken(let token): return token.$createdBy.id
            }
        }
    }

    var description: String {
        switch self {
        case .user(let user): return user.email
        case .deployToken(let token): return "배포 토큰 '\(token.name)'"
        }
    }
}

extension Request {
    /// 이 앱에 올릴 수 있는 자격을 확인하고 누구인지 돌려준다.
    ///
    /// 배포 토큰은 자기 앱에만 통한다. 다른 앱의 주소에 들이대면 그 앱의 존재조차
    /// 알려주지 않고 404 로 답한다. 토큰 하나로 남의 앱 목록을 훑는 것을 막는다.
    func requireUploadRights(to app: App) async throws -> UploadPrincipal {
        if let token = deployToken {
            guard token.$app.id == (try app.requireID()) else {
                throw Abort(.notFound, reason: "앱을 찾을 수 없습니다.")
            }
            return .deployToken(token)
        }

        let user = try requireUser()
        try await app.requireUploadAccess(for: user, on: db)
        return .user(user)
    }

    /// 자격이 있으면 그것을, 없으면 nil.
    ///
    /// 목록처럼 "전부 볼 수 있는가"만 가르면 되는 경로에서 쓴다. 인증 자체가 없으면
    /// 여전히 401 이다. 로그인하지 않은 사람에게는 출시본조차 보여주지 않는다.
    func uploadRights(to app: App) async throws -> UploadPrincipal? {
        if let token = deployToken {
            guard token.$app.id == (try app.requireID()) else {
                throw Abort(.notFound, reason: "앱을 찾을 수 없습니다.")
            }
            return .deployToken(token)
        }

        let user = try requireUser()
        return try await app.canUpload(user, on: db) ? .user(user) : nil
    }
}
