import AlleyShared
import Testing
import VaporTesting

@testable import AlleyServer

/// 종료 중에 긴 폴링이 데이터베이스를 다시 잡지 않는지 본다.
///
/// 잡으면 프로세스가 죽는다. `request.db` 는 강제 언래핑이고, 데이터베이스는 종료
/// 과정에서 핸들러보다 먼저 닫힌다 (ADR-0052). 크래시 자체는 시험으로 재현할 수
/// 없으므로 - 재현하려면 시험 프로세스가 죽어야 한다 - 그 앞 단계를 붙잡는다.
/// 폴링이 신호를 보고 스스로 빠져나오면 뒤이은 일도 일어나지 않는다.
@Suite("종료 신호")
struct ShutdownSignalTests {
    @Test("열려 있는 폴링이 없으면 기다리지 않는다")
    func returnsWhenNothingIsOpen() async throws {
        let signal = ShutdownSignal()
        let started = ContinuousClock.now

        await signal.waitForOpenPolls(timeout: .seconds(3))

        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    @Test("폴링이 빠져나가면 기다림도 끝난다")
    func stopsWaitingWhenPollLeaves() async throws {
        let signal = ShutdownSignal()
        signal.enter()
        #expect(signal.openPolls == 1)

        async let waiting: Void = signal.waitForOpenPolls(timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(100))
        signal.leave()

        let started = ContinuousClock.now
        await waiting
        // 상한(5초)까지 가지 않고 폴링이 빠지자마자 돌아와야 한다.
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(signal.openPolls == 0)
    }

    @Test("돌아오지 않는 폴링이 있어도 상한에서 포기한다")
    func givesUpAtTheDeadline() async throws {
        let signal = ShutdownSignal()
        signal.enter()

        // 여기서 영영 기다리면 기다리는 쪽이 종료를 붙잡는다. 포기해도 최악은
        // 고치기 전과 같다.
        await signal.waitForOpenPolls(timeout: .milliseconds(200))

        #expect(signal.openPolls == 1)
    }
}

@Suite("종료 중 잡 폴링")
struct ShutdownPollingTests {
    @Test("종료가 시작됐으면 기다리지 않고 빈손으로 끝낸다")
    func pollReturnsImmediatelyWhileShuttingDown() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeWorker()
            app.shutdownSignal.begin()

            let started = ContinuousClock.now
            // 25초를 기다리라고 해도 기다리지 않는다. 기다리는 동안 데이터베이스가
            // 닫히고, 그 다음 회전이 프로세스를 죽인다.
            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=25", headers: .bearer(token)
            ) { response in
                #expect(response.status == .noContent)
            }
            #expect(ContinuousClock.now - started < .seconds(5))
        }
    }

    @Test("폴링이 끝나면 열린 수가 0 으로 돌아온다")
    func releasesTheSlotWhenDone() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeWorker()

            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(token)
            ) { #expect($0.status == .noContent) }

            // 여기서 세다 남으면 종료가 상한까지 기다리게 된다.
            #expect(app.shutdownSignal.openPolls == 0)
        }
    }
}
