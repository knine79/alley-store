import AlleyShared
import Fluent
import JWT
import Vapor

/// 세션 쿠키의 이름. 웹 콘솔이 로그인 후 이 쿠키를 받는다.
public let sessionCookieName = "alley_session"

/// 로그아웃한 사람이 다음 로그인에서 공급자 인증을 다시 거치게 하는 표시.
///
/// **로그아웃은 우리 쪽 쿠키만 지운다.** 공급자 세션은 그대로라, 곧바로 로그인을
/// 누르면 아무것도 묻지 않고 같은 계정으로 들어간다. 로그아웃을 누른 사람이 기대하는
/// 동작이 아니고, 공용 맥에서는 다음 사람이 그대로 들어간다.
///
/// 그래서 로그아웃할 때 이 표시를 남기고, 다음 로그인 요청에 `prompt=login` 을 실어
/// 공급자에게 다시 물어보게 한다. 표시는 그 한 번으로 지운다.
public let reauthenticationCookieName = "alley_reauth"

/// 세션 토큰을 확인하고 요청에 사용자를 붙인다.
///
/// 토큰은 신원만 증명하므로 역할은 여기서 데이터베이스를 읽어 채운다
/// (`SessionToken` 참고). 그래서 권한 변경이 다음 요청부터 바로 반영된다.
///
/// 토큰을 받는 자리는 둘이다. 스토어 앱은 `Authorization: Bearer` 헤더로 보내고,
/// 웹 콘솔은 브라우저가 자동으로 붙이는 `alley_session` 쿠키를 쓴다.
/// 웹에서 헤더를 쓰려면 토큰을 자바스크립트가 읽을 수 있는 곳에 둬야 해서
/// HttpOnly 쿠키의 이점이 사라진다.
public struct SessionAuthenticator: AsyncMiddleware {
    public init() {}

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        if let rawToken = token(from: request), let user = await user(for: rawToken, on: request) {
            request.auth.login(user)
        }
        return try await next.respond(to: request)
    }

    /// 헤더를 쿠키보다 먼저 본다.
    ///
    /// 브라우저는 같은 출처의 모든 요청에 쿠키를 자동으로 붙인다. 헤더를 명시한
    /// 요청은 그 신원으로 부르겠다는 뜻이므로 자동으로 붙은 쿠키가 이겨서는 안 된다.
    private func token(from request: Request) -> String? {
        if let bearer = request.headers.bearerAuthorization {
            return bearer.token
        }
        return request.cookies[sessionCookieName]?.string
    }

    private func user(for rawToken: String, on request: Request) async -> User? {
        do {
            let token = try await request.jwt.verify(rawToken, as: SessionToken.self)
            guard let userID = token.userID else { return nil }
            // 토큰은 유효한데 사용자가 사라진 경우가 있다. 계정 삭제 후 남은 토큰이다.
            return try await User.find(userID, on: request.db)
        } catch {
            // 만료나 서명 불일치는 인증 실패로만 다룬다. 자세한 이유는 로그에만 남긴다.
            request.logger.debug("세션 토큰 검증 실패: \(error)")
            return nil
        }
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
