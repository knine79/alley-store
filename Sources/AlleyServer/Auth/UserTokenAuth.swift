import AlleyShared
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
///
/// **부를 수 있는 경로를 목록으로 정한다** (`UserTokenScope`).
///
/// 처음에는 "지우는 것만 막자" 로 두었다가 뒤집었다. `DELETE` 만 걸러내면
/// `POST /api/v1/apps/:id/deploy-tokens` 가 그대로 열려 있고, 그것으로 만든 배포
/// 토큰은 **만료도 없고 계정을 끊어도 살아남는다.** 90일 수명과 퇴사 차단을 한
/// 번에 넘어간다. 피드 토큰도, 관리자라면 워커 등록과 역할 변경도 같다.
///
/// 막을 것을 세는 방식은 경로가 늘어날 때마다 새는 곳이 생긴다. 열 것을 세면 새
/// 경로는 기본이 닫힘이다.
struct UserTokenAuthenticator: AsyncMiddleware {
    /// 마지막 사용 시각을 다시 쓰기까지 기다리는 시간.
    static let usageResolution: TimeInterval = 300

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

        // **무엇을 부를 수 있는지는 인증을 통과한 뒤에 본다.** 순서를 바꾸면 발급된
        // 적 없는 값에도 "그 경로는 못 부릅니다" 가 돌아가고, 그것만으로 `alleyu_`
        // 가 쓰이는 접두어라는 것이 새어 나간다. 폐기와 만료를 가려 말하는 것도
        // 같은 이유로 여기 뒤에 있어야 한다.
        guard UserTokenScope.allows(method: request.method, path: request.url.path) else {
            request.logger.notice(
                "사람 토큰이 열리지 않은 경로를 불렀습니다 [\(request.method) \(request.url.path)]"
            )
            throw Abort(
                .forbidden,
                reason: """
                    사람 토큰으로 부를 수 있는 경로가 아닙니다. 지우거나 자격증명을 \
                    만드는 일은 웹 콘솔에서 사람이 합니다.
                    """
            )
        }

        // 마지막으로 쓴 때를 남긴다. "이 토큰 아직 쓰나" 를 이것으로 판단한다.
        //
        // **매 요청마다 쓰지 않는다.** 에이전트는 상태를 확인하려고 같은 경로를 짧은
        // 간격으로 부른다. 그때마다 UPDATE 를 끼우면 읽기만 하는 왕복이 두 배가 되고,
        // 그 쓰기가 실패하면 멀쩡한 조회가 500 이 된다. 분 단위로 안다면 충분하다.
        if token.lastUsedAt.map({ Date().timeIntervalSince($0) > Self.usageResolution }) ?? true {
            token.lastUsedAt = Date()
            // 실패해도 요청은 계속 간다. 마지막 사용 시각은 다음 요청에 다시 쓴다.
            try? await token.save(on: request.db)
        }

        request.auth.login(token.user)
        return try await next.respond(to: request)
    }
}
