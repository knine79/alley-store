import Foundation
import Testing

@testable import AlleyWorkerCore

/// 게이트웨이가 끊은 폴링을 서버 장애로 읽지 않게 한다.
///
/// 앞단 프록시의 타임아웃이 `ALLEY_POLL_TIMEOUT` 보다 짧으면 큐가 빌 때마다
/// 502·504 가 난다. 잡이 있을 때는 곧바로 응답이 와서 서명은 멀쩡히 돌기 때문에,
/// 로그만 보고 서버와 네트워크를 한참 뒤지게 된다.
@Suite("폴링 실패 안내")
struct PollTimeoutHintTests {
    @Test("게이트웨이 타임아웃에는 어디를 볼지 알려준다", arguments: [502, 504])
    func hintsAtPollTimeout(status: Int) {
        let hint = WorkerLoop.hint(
            for: WorkerClient.ClientError.badResponse(status: status, reason: nil),
            pollTimeout: 30
        )
        #expect(hint.contains("ALLEY_POLL_TIMEOUT"))
        // 지금 값을 함께 보여줘야 무엇과 견줘 줄일지 판단할 수 있다.
        #expect(hint.contains("30"))
    }

    /// 다른 실패까지 이 안내를 붙이면 프록시를 의심하게 만든다. 그건 지금 문제를
    /// 반대 방향으로 옮기는 것뿐이다.
    @Test("다른 실패에는 붙이지 않는다")
    func staysQuietForOtherFailures() {
        let others: [any Error] = [
            WorkerClient.ClientError.badResponse(status: 401, reason: "토큰이 막혔습니다."),
            WorkerClient.ClientError.badResponse(status: 500, reason: nil),
            WorkerClient.ClientError.malformedPayload,
            WorkerClient.ClientError.transport(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            ),
        ]
        for error in others {
            #expect(WorkerLoop.hint(for: error, pollTimeout: 30).isEmpty)
        }
    }
}
