import Fluent
import Foundation
import Vapor

/// 사람 토큰으로 온 요청을 그 사람으로 인증한다 (ADR-0060).
///
/// **세션과 같은 자리에 선다.** 인증에 성공하면 `request.auth` 에 그 사람이 들어가고,
/// 그 뒤로는 화면을 여는 요청과 구별되지 않는다. 권한을 따로 좁히지 않기로 했으므로
/// 그게 맞다 (ADR-0060). 좁히려면 여기가 아니라 권한 판단 쪽을 고쳐야 한다.
///
/// 전역 스택에 둔다. 컨트롤러마다 붙이면 붙이는 것을 잊은 경로가 생기고, 그 경로는
/// 화면으로는 되는데 토큰으로는 안 되는 상태가 된다. `alleyu_` 로 시작하는 값이
/// 없으면 아무것도 하지 않으므로 다른 인증을 방해하지 않는다.
struct UserTokenAuthenticator: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization,
              bearer.token.hasPrefix(UserToken.prefix)
        else {
            return try await next.respond(to: request)
        }

        let hash = UserToken.hash(token: bearer.token)
        guard let token = try await UserToken.query(on: request.db)
            .filter(\.$tokenHash == hash)
            .with(\.$user)
            .first()
        else {
            // 어떤 값이 왔는지는 남기지 않는다. 로그가 자격증명 저장소가 되면 안 된다.
            request.logger.warning("알 수 없는 사람 토큰으로 접근 [path: \(request.url.path)]")
            throw Abort(.unauthorized, reason: "토큰이 올바르지 않습니다.")
        }

        guard token.revokedAt == nil else {
            throw Abort(.unauthorized, reason: "폐기된 토큰입니다. 내 설정에서 새로 발급하세요.")
        }
        // 만료와 폐기를 가려서 말한다. 만료는 스스로 고칠 수 있고 폐기는 누가 끊은
        // 것이라, 받는 사람이 할 일이 다르다.
        guard token.expiresAt > Date() else {
            throw Abort(.unauthorized, reason: "만료된 토큰입니다. 내 설정에서 새로 발급하세요.")
        }
        // 끊은 사람의 토큰은 살아 있어도 쓸 수 없다 (ADR-0061). 끊을 때 함께
        // 폐기하지만, 그 사이에 발급된 것이나 놓친 것이 있어도 여기서 막힌다.
        guard token.user.isActive else {
            request.logger.notice("끊은 계정의 토큰 [이메일: \(token.user.email)]")
            throw Abort(.unauthorized, reason: "끊은 계정입니다.")
        }

        // 마지막으로 쓴 때를 남긴다. "이 토큰 아직 쓰나" 를 이것으로 판단한다.
        token.lastUsedAt = Date()
        try await token.save(on: request.db)

        request.auth.login(token.user)
        return try await next.respond(to: request)
    }
}
