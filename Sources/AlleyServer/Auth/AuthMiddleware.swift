import AlleyShared
import Fluent
import JWT
import Vapor

/// 세션 토큰을 확인하고 요청에 사용자를 붙인다.
///
/// 토큰은 신원만 증명하므로 역할은 여기서 데이터베이스를 읽어 채운다
/// (`SessionToken` 참고). 그래서 권한 변경이 다음 요청부터 바로 반영된다.
public struct SessionAuthenticator: AsyncBearerAuthenticator {
    public init() {}

    public func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let token: SessionToken
        do {
            token = try await request.jwt.verify(bearer.token, as: SessionToken.self)
        } catch {
            // 만료나 서명 불일치는 인증 실패로만 다룬다. 자세한 이유는 로그에만 남긴다.
            request.logger.debug("세션 토큰 검증 실패: \(error)")
            return
        }

        guard let userID = token.userID else { return }
        guard let user = try await User.find(userID, on: request.db) else {
            // 토큰은 유효한데 사용자가 사라진 경우. 계정 삭제 후 남은 토큰이다.
            return
        }
        request.auth.login(user)
    }
}

extension User: Authenticatable {}

extension Request {
    /// 로그인한 사용자. 없으면 401.
    public func requireUser() throws -> User {
        try auth.require(User.self)
    }

    /// 앱을 등록하고 버전을 올릴 수 있는 사용자. 아니면 403.
    public func requirePublisher() throws -> User {
        let user = try requireUser()
        guard user.role.canPublish else {
            throw Abort(.forbidden, reason: "앱을 등록하거나 배포할 권한이 없습니다.")
        }
        return user
    }

    /// 관리자. 아니면 403.
    public func requireAdmin() throws -> User {
        let user = try requireUser()
        guard user.role.canAdminister else {
            throw Abort(.forbidden, reason: "관리자 권한이 필요합니다.")
        }
        return user
    }
}
