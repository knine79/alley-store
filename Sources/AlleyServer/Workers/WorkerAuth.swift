import AlleyShared
import Fluent
import Foundation
import Vapor

/// 워커 토큰으로 인증한다.
///
/// 사용자 세션과 완전히 분리된 경로다. 워커는 사람이 아니고, 사람의 권한으로 잡을
/// 가져가지도 않는다. 하나의 미들웨어가 둘 다 다루면 "이 토큰이 사용자 것인가 워커
/// 것인가"를 매 요청 판단해야 하고, 그 판단이 틀리면 권한이 새는 방향으로 틀린다.
///
/// 토큰은 `Authorization: Bearer` 로 받는다. 쿠키는 보지 않는다. 워커는 브라우저가
/// 아니므로 쿠키를 쓸 이유가 없고, 쓰지 않으면 CSRF 를 생각할 필요도 없다.
struct WorkerAuthenticator: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "워커 토큰이 필요합니다.")
        }

        let hash = Worker.hash(token: bearer.token)
        guard let worker = try await Worker.query(on: request.db)
            .filter(\.$tokenHash == hash)
            .first()
        else {
            // 어떤 토큰이 왔는지는 남기지 않는다. 로그가 자격증명 저장소가 되면 안 된다.
            request.logger.warning("알 수 없는 워커 토큰으로 접근 [path: \(request.url.path)]")
            throw Abort(.unauthorized, reason: "워커 토큰이 올바르지 않습니다.")
        }
        guard worker.isActive else {
            throw Abort(.unauthorized, reason: "폐기된 워커 토큰입니다. 관리자에게 재발급을 요청하세요.")
        }

        // 잡을 받아가든 상태를 보고하든, 말을 걸었다는 것 자체가 살아 있다는 신호다.
        worker.lastSeenAt = Date()
        try await worker.save(on: request.db)

        request.workerIdentity = worker
        return try await next.respond(to: request)
    }
}

extension Request {
    private struct WorkerKey: StorageKey {
        typealias Value = Worker
    }

    /// 이 요청을 보낸 워커. `WorkerAuthenticator` 를 지난 경로에서만 채워진다.
    var workerIdentity: Worker? {
        get { storage[WorkerKey.self] }
        set { storage[WorkerKey.self] = newValue }
    }

    func requireWorker() throws -> Worker {
        guard let worker = workerIdentity else {
            throw Abort(.unauthorized, reason: "워커 토큰이 필요합니다.")
        }
        return worker
    }
}
