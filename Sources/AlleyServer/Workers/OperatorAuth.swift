import AlleyShared
import Fluent
import Foundation
import Vapor

/// 운영 토큰으로 인증한다 (ADR-0043).
///
/// 관리자 API 는 세션 쿠키로만 인증한다. 운영 파이프라인은 브라우저가 아니라
/// 로그인할 수 없으므로 별도 경로가 필요하다.
///
/// 토큰은 `Authorization: Bearer` 로 받는다. 쿠키는 보지 않는다. 파이프라인은
/// 브라우저가 아니므로 쿠키를 쓸 이유가 없고, 쓰지 않으면 CSRF 를 생각할 필요도 없다.
struct OperatorAuthenticator: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "운영 토큰이 필요합니다.")
        }

        // **잘못 넣은 토큰을 알아보게 한다.** 값만 보고 어느 종류인지 알 수 있는데
        // "올바르지 않습니다" 로 끝내면, 설정 파일에 배포 토큰을 넣은 사람이 무엇이
        // 잘못됐는지 찾는 데 한참 걸린다.
        if bearer.token.hasPrefix(DeployToken.prefix) {
            throw Abort(
                .unauthorized,
                reason: "배포 토큰(\(DeployToken.prefix)…)입니다. 운영 토큰(\(OperatorToken.prefix)…)이 필요합니다."
            )
        }

        let hash = OperatorToken.hash(token: bearer.token)
        guard let token = try await OperatorToken.query(on: request.db)
            .filter(\.$tokenHash == hash)
            .with(\.$createdBy)
            .first()
        else {
            // 어떤 토큰이 왔는지는 남기지 않는다. 로그가 자격증명 저장소가 되면 안 된다.
            request.logger.warning("알 수 없는 운영 토큰으로 접근 [path: \(request.url.path)]")
            throw Abort(.unauthorized, reason: "운영 토큰이 올바르지 않습니다.")
        }
        guard token.isActive else {
            throw Abort(.unauthorized, reason: "폐기된 운영 토큰입니다. 관리자에게 재발급을 요청하세요.")
        }

        token.lastUsedAt = Date()
        try await token.save(on: request.db)

        request.operatorIdentity = token
        return try await next.respond(to: request)
    }
}

extension Request {
    private struct OperatorKey: StorageKey {
        typealias Value = OperatorToken
    }

    /// 이 요청을 보낸 운영 토큰. `OperatorAuthenticator` 를 지난 경로에서만 채워진다.
    var operatorIdentity: OperatorToken? {
        get { storage[OperatorKey.self] }
        set { storage[OperatorKey.self] = newValue }
    }

    func requireOperator() throws -> OperatorToken {
        guard let token = operatorIdentity else {
            throw Abort(.unauthorized, reason: "운영 토큰이 필요합니다.")
        }
        return token
    }
}
