import FluentPostgresDriver
import Foundation
import Vapor

/// 인스턴스가 여러 대여도 한 번에 하나만 돌아야 하는 일을 감싸는 Postgres advisory lock.
///
/// 데이터베이스가 이미 있고 모든 인스턴스가 그 하나를 본다. 리더 선출을 따로 붙일
/// 이유가 없다 (ADR-0028).
///
/// **세션 단위(`pg_advisory_lock`)를 쓴다.** 트랜잭션 단위(`pg_advisory_xact_lock`)는
/// 잠금을 잡은 트랜잭션이 끝날 때 풀린다. 우리가 지켜야 하는 구간은 트랜잭션 하나가
/// 아니다. 마이그레이션은 각자 자기 트랜잭션에서 돌고(Fluent 가 그렇게 만든다) 그
/// 여러 개를 통째로 감싸야 한다. 트랜잭션 단위 잠금으로 그걸 하려면 마이그레이션
/// 전부를 우리가 만든 트랜잭션 안에 넣어야 하는데, Fluent 는 그럴 자리를 주지 않는다.
///
/// **잠금을 쥔 커넥션이 죽으면 Postgres 가 알아서 놓아준다.** 세션 잠금의 수명은 그
/// 세션이고, 세션은 TCP 연결이 끊기면 사라진다. 파드가 마이그레이션 도중에 죽어도
/// 잠금이 데이터베이스에 남아 다음 파드를 영원히 막는 일은 없다. 다만 그때 스키마는
/// 반쯤 적용된 상태로 남는다. 그건 이 잠금이 풀어주는 문제가 아니다.
///
/// **커넥션을 풀에서 빌리지 않고 직접 연다.** 세션 잠금은 쥐고 있는 동안 커넥션
/// 하나를 계속 점유한다. Vapor 의 Postgres 풀은 이벤트 루프마다 커넥션 한 개가
/// 기본값이라, 풀에서 빌려 잠그면 같은 이벤트 루프에 배정된 다음 질의가 커넥션을
/// 얻지 못하고 굳는다. 마이그레이션이 바로 그 다음 질의다.
enum AdvisoryLock {
    /// 잠금이 지키는 일.
    ///
    /// advisory lock 의 이름 공간은 데이터베이스 전역이다. 값이 겹치면 서로 아무
    /// 관계도 없는 두 일이 상대를 기다린다. 그래서 키를 만드는 곳을 여기 하나로
    /// 둔다. 새 용도가 생기면 케이스를 더하고, 한 번 나간 숫자는 다시 쓰지 않는다.
    enum Purpose: Int32 {
        /// 부팅할 때 스키마를 맞추는 구간 (ADR-0028).
        case migration = 1

        // 다음 자리는 ADR-0018 의 후속 과제인 주기적 훑기다. 서버를 여러 대로 늘릴
        // 때 여기에 케이스를 더해 `StalledJobSweep` 과 `DraftSweep` 의 본문을
        // `withLock(_:on:waitingUpTo:)` 으로 감싸면 된다. 훑기는 기다릴 이유가
        // 없으므로 한도를 `.zero` 로 주고 `Failure.timedOut` 을 이번엔 넘어가는
        // 신호로 받으면 된다.

        /// 로그에 찍히는 이름.
        var label: String {
            switch self {
            case .migration: return "부팅 시 마이그레이션"
            }
        }

        /// advisory lock 의 키.
        ///
        /// 키는 64비트 정수 하나이고, 그 이름 공간을 이 데이터베이스에 붙는 모든
        /// 도구가 함께 쓴다. `1`, `2`, `100` 같은 작은 수는 아무나 고르는 값이라
        /// 부딪히기 쉽다. 그래서 상위 32비트를 Alley 고유값으로 고정하고 하위
        /// 32비트만 용도에 쓴다. 고정값은 ASCII `"ally"` 다.
        var key: Int64 {
            0x616C_6C79 << 32 | Int64(rawValue)
        }
    }

    /// 잠금을 얻지 못한 경우.
    enum Failure: Error, CustomStringConvertible {
        /// 제한 시간 안에 잠금이 풀리지 않았다.
        case timedOut(purpose: Purpose, waited: Duration)
        /// 잠금 함수가 값을 돌려주지 않았다.
        case noResult(purpose: Purpose)

        var description: String {
            switch self {
            case .timedOut(let purpose, let waited):
                return "'\(purpose.label)' 잠금을 \(waited) 동안 기다렸지만 다른 인스턴스가 놓지 않았습니다."
            case .noResult(let purpose):
                return "'\(purpose.label)' 잠금을 요청했는데 데이터베이스가 결과를 주지 않았습니다."
            }
        }
    }

    /// 잠금을 다시 시도하는 간격.
    ///
    /// `pg_advisory_lock` 으로 막히게 기다리면 왕복이 한 번으로 끝나지만, 기다리는
    /// 중이라는 것을 로그로 알릴 수 없고 취소도 걸리지 않는다. 그래서
    /// `pg_try_advisory_lock` 을 이 간격으로 다시 던진다. 마이그레이션 하나가
    /// 초 단위로 끝나는 규모라 1초면 충분히 촘촘하다.
    private static let retryInterval: Duration = .seconds(1)

    /// 잠금을 잡고 본문을 돌린다. 끝나면 놓는다.
    ///
    /// `waitingUpTo` 를 `.zero` 로 주면 한 번만 시도하고, 못 얻으면 곧바로
    /// `Failure.timedOut` 을 던진다. 기다릴 이유가 없는 호출자를 위한 형태다.
    static func withLock<T>(
        _ purpose: Purpose,
        on application: Application,
        waitingUpTo timeout: Duration,
        _ body: () async throws -> T
    ) async throws -> T {
        let logger = application.logger
        let connection = try await PostgresConnection.connect(
            on: application.eventLoopGroup.any(),
            configuration: application.postgresConfiguration,
            // 로그 메타데이터에만 쓰이는 값이다. 프로세스 안에서 유일할 필요는 없다.
            id: 0,
            logger: logger
        )

        do {
            try await acquire(purpose, on: connection, waitingUpTo: timeout, logger: logger)
        } catch {
            try? await connection.close()
            throw error
        }

        // 놓는 것을 `defer` 에 두지 않는다. 본문이 실패했을 때 놓기까지 실패하면
        // 그 오류가 원래 오류를 덮어버린다. 원래 오류를 살려서 던진다.
        do {
            let result = try await body()
            await release(purpose, on: connection, logger: logger)
            return result
        } catch {
            await release(purpose, on: connection, logger: logger)
            throw error
        }
    }

    private static func acquire(
        _ purpose: Purpose,
        on connection: PostgresConnection,
        waitingUpTo timeout: Duration,
        logger: Logger
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var announcedWait = false

        while true {
            if try await tryLock(purpose, on: connection, logger: logger) {
                if announcedWait {
                    logger.notice(
                        "'\(purpose.label)' 잠금을 \(started.duration(to: clock.now)) 기다린 뒤 얻었습니다."
                    )
                }
                return
            }

            let waited = started.duration(to: clock.now)
            guard waited < timeout else {
                throw Failure.timedOut(purpose: purpose, waited: waited)
            }
            if !announcedWait {
                announcedWait = true
                logger.notice(
                    "다른 인스턴스가 '\(purpose.label)' 잠금을 쥐고 있어 기다립니다. 최대 \(timeout)."
                )
            }
            // 남은 시간보다 오래 자면 한도를 넘겨서 깬다.
            try await Task.sleep(for: min(retryInterval, timeout - waited))
        }
    }

    private static func tryLock(
        _ purpose: Purpose,
        on connection: PostgresConnection,
        logger: Logger
    ) async throws -> Bool {
        let rows = try await connection.query(
            "SELECT pg_try_advisory_lock(\(purpose.key))",
            logger: logger
        ).collect()
        guard let acquired = try rows.first?.decode(Bool.self) else {
            throw Failure.noResult(purpose: purpose)
        }
        return acquired
    }

    /// 잠금을 놓고 커넥션을 닫는다.
    ///
    /// 커넥션을 닫는 것만으로도 Postgres 가 세션 잠금을 놓는다. 그래도 먼저 명시적으로
    /// 푸는 이유는 그쪽이 즉시이기 때문이다. 닫기는 TCP 가 정리될 때까지 걸릴 수 있고,
    /// 그 사이 기다리는 쪽은 계속 기다린다.
    ///
    /// 실패를 삼킨다. 여기서 던지면 본문이 성공했는데도 호출자가 실패로 받는다.
    /// 놓기에 실패해도 커넥션이 끊기는 순간 Postgres 가 정리한다.
    private static func release(
        _ purpose: Purpose,
        on connection: PostgresConnection,
        logger: Logger
    ) async {
        do {
            _ = try await connection.query(
                "SELECT pg_advisory_unlock(\(purpose.key))",
                logger: logger
            ).collect()
        } catch {
            logger.warning("'\(purpose.label)' 잠금을 명시적으로 놓지 못했습니다: \(error)")
        }
        try? await connection.close()
    }
}

// MARK: - Vapor 연동

extension Application {
    private struct PostgresConfigurationKey: StorageKey {
        typealias Value = PostgresConnection.Configuration
    }

    /// 커넥션 풀을 거치지 않고 직접 연결할 때 쓰는 접속 설정.
    ///
    /// 풀에서 빌리면 안 되는 이유는 `AdvisoryLock` 에 적어뒀다. 풀과 같은 값에서
    /// 나와야 하므로 `configureDatabase` 가 여기에 넣는다.
    var postgresConfiguration: PostgresConnection.Configuration {
        get {
            guard let configuration = storage[PostgresConfigurationKey.self] else {
                fatalError("데이터베이스가 설정되기 전에 접근했습니다. configure(_:) 를 먼저 호출하세요.")
            }
            return configuration
        }
        set { storage[PostgresConfigurationKey.self] = newValue }
    }
}
