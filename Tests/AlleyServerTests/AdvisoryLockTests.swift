import Testing
import VaporTesting

@testable import AlleyServer

/// advisory lock 이 실제로 배타적인지 확인한다.
///
/// 흉내로는 검증되지 않는다. 잠금의 의미는 Postgres 안에 있고, 우리가 확인하려는
/// 것은 "두 세션이 같은 키를 동시에 잡으려 하면 하나만 통과한다" 다. 그래서 진짜
/// 데이터베이스를 상대한다. 스키마는 필요 없다.
///
/// 여기 테스트들은 **같은 키**를 쓴다. 병렬로 돌면 서로가 서로의 잠금을 기다린다.
/// 스위트 안은 `.serialized` 로, 스위트 밖은 `withDatabaseLock` 으로 세운다.
/// 부팅 시 마이그레이션 테스트가 같은 키를 잡기 때문이다.
@Suite("advisory lock", .serialized)
struct AdvisoryLockTests {
    @Test("한쪽이 쥐고 있으면 다른 쪽은 얻지 못한다")
    func lockIsExclusive() async throws {
        try await withDatabaseLock {
            try await withConfiguredApp { app in
                try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {
                    // 같은 앱이지만 잠금마다 커넥션을 새로 연다. Postgres 에서 서로
                    // 다른 세션이므로 두 번째는 막혀야 한다. 여기서 통과하면 잠금이
                    // 아무 일도 하지 않는 것이다.
                    _ = await #expect(throws: AdvisoryLock.Failure.self) {
                        try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {}
                    }
                }
            }
        }
    }

    @Test("본문이 끝나면 놓는다")
    func lockIsReleasedAfterBody() async throws {
        try await withDatabaseLock {
            try await withConfiguredApp { app in
                try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {}
                // 앞에서 놓지 않았으면 여기서 걸린다.
                try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {}
            }
        }
    }

    @Test("본문이 실패해도 놓는다")
    func lockIsReleasedWhenBodyThrows() async throws {
        struct Boom: Error {}

        try await withDatabaseLock {
            try await withConfiguredApp { app in
                await #expect(throws: Boom.self) {
                    try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {
                        throw Boom()
                    }
                }
                try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {}
            }
        }
    }

    @Test("기다리는 쪽은 잠금이 풀린 뒤에 들어간다")
    func waiterProceedsAfterRelease() async throws {
        try await withDatabaseLock {
            try await withConfiguredApp { app in
                let holdTime = Duration.milliseconds(500)
                var waiter: Task<Duration, any Error>?

                try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {
                    // 잠금을 이미 잡은 뒤에 기다리는 쪽을 띄운다. 순서를 이렇게 두지
                    // 않으면 둘 중 누가 먼저 잡을지가 경쟁이 되어 테스트가 흔들린다.
                    waiter = Task {
                        let clock = ContinuousClock()
                        let started = clock.now
                        try await AdvisoryLock.withLock(
                            .migration,
                            on: app,
                            waitingUpTo: .seconds(30)
                        ) {}
                        return started.duration(to: clock.now)
                    }
                    try await Task.sleep(for: holdTime)
                }

                // 기다린 시간이 쥐고 있던 시간에 가까워야 한다. 곧바로 들어왔다면
                // 잠금을 무시한 것이다. 재시도 간격이 1초라 여유를 두고 비교한다.
                let waited = try await waiter?.value
                #expect(waited != nil)
                #expect(waited ?? .zero >= holdTime - .milliseconds(200))
            }
        }
    }

    @Test("잠금 키는 용도마다 다르고 Alley 이름 공간 안에 있다")
    func lockKeysAreNamespaced() {
        // 이름 공간이 데이터베이스 전역이라 작은 정수를 쓰면 남의 잠금과 부딪힌다.
        // 상위 32비트가 고정값인지, 하위 32비트가 용도인지 본다.
        for purpose in [AdvisoryLock.Purpose.migration] {
            #expect(purpose.key >> 32 == 0x616C_6C79)
            #expect(purpose.key & 0xFFFF_FFFF == Int64(purpose.rawValue))
        }
    }
}
