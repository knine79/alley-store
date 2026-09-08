import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 부팅 시 마이그레이션 (ADR-0028).
///
/// 확인할 것은 셋이다. 기본값이 꺼짐인가, 켜면 요청을 받기 전에 스키마가 올라가는가,
/// 잠금을 못 얻으면 뜨지 않는가.
@Suite("부팅 시 마이그레이션", .serialized)
struct BootMigrationTests {
    /// 스키마를 확실히 비운다.
    ///
    /// 앞선 테스트가 남긴 표가 있으면 "부팅하면서 만들었다"와 "이미 있었다"를
    /// 구별할 수 없다.
    private func emptySchema() async throws {
        try await withApp { app in
            try await configure(app, config: try TestSupport.config())
            try await app.autoRevert()
        }
    }

    @Test("MIGRATE_ON_BOOT 를 읽고, 없으면 꺼진 것으로 본다")
    func readsEnvironmentFlag() throws {
        #expect(try TestSupport.config().database.migrateOnBoot == false)
        #expect(try TestSupport.config(overrides: ["MIGRATE_ON_BOOT": "1"]).database.migrateOnBoot)
        #expect(try TestSupport.config(overrides: ["MIGRATE_ON_BOOT": "true"]).database.migrateOnBoot)
        #expect(try TestSupport.config(overrides: ["MIGRATE_ON_BOOT": "0"]).database.migrateOnBoot == false)
    }

    @Test("기본값은 꺼짐이라 부팅해도 스키마를 건드리지 않는다")
    func doesNotMigrateByDefault() async throws {
        try await withDatabaseLock {
            try await emptySchema()

            try await withApp { app in
                try await configure(app, config: try TestSupport.config())
                // 표가 없어야 한다. 있으면 기존 배포의 동작이 바뀐 것이다.
                await #expect(throws: (any Error).self) {
                    _ = try await User.query(on: app.db).count()
                }
            }
        }
    }

    @Test("켜면 configure 를 마치는 시점에 스키마가 올라가 있다")
    func migratesDuringConfigureWhenEnabled() async throws {
        try await withDatabaseLock {
            try await emptySchema()

            try await withApp { app in
                try await configure(
                    app,
                    config: try TestSupport.config(overrides: ["MIGRATE_ON_BOOT": "1"])
                )
                do {
                    // configure 가 끝난 직후다. 라우트가 열리기 전이라는 뜻이다.
                    #expect(try await User.query(on: app.db).count() == 0)
                    try await app.autoRevert()
                } catch {
                    try? await app.autoRevert()
                    throw error
                }
            }
        }
    }

    @Test("이미 적용된 스키마 위에서 다시 켜도 그냥 뜬다")
    func secondBootIsNoOp() async throws {
        try await withDatabaseLock {
            try await emptySchema()

            let config = try TestSupport.config(overrides: ["MIGRATE_ON_BOOT": "1"])
            try await withApp { app in
                try await configure(app, config: config)
            }
            // 기다렸다 들어온 인스턴스가 겪는 상황이다. Fluent 가 `_fluent_migrations`
            // 를 보고 건너뛰어야 하고, 그 판단이 잠금 안에서 일어나야 한다.
            try await withApp { app in
                try await configure(app, config: config)
                do {
                    #expect(try await User.query(on: app.db).count() == 0)
                    try await app.autoRevert()
                } catch {
                    try? await app.autoRevert()
                    throw error
                }
            }
        }
    }

    @Test("잠금을 얻지 못하면 마이그레이션을 돌리지 않고 실패한다")
    func failsWhenLockIsHeld() async throws {
        try await withDatabaseLock {
            try await emptySchema()

            try await withApp { app in
                let config = try TestSupport.config(overrides: ["MIGRATE_ON_BOOT": "1"])
                // 꺼진 설정으로 먼저 띄워서 잠금만 잡는다. 다른 인스턴스가 마이그레이션
                // 중인 상황이다.
                try await configure(app, config: try TestSupport.config())

                try await AdvisoryLock.withLock(.migration, on: app, waitingUpTo: .zero) {
                    await #expect(throws: AdvisoryLock.Failure.self) {
                        try await BootMigration.runIfEnabled(
                            on: app,
                            config: config,
                            waitingUpTo: .zero
                        )
                    }
                }

                // 잠금 없이 밀고 들어가지 않았는지 본다. 표가 생겼으면 그런 것이다.
                await #expect(throws: (any Error).self) {
                    _ = try await User.query(on: app.db).count()
                }
            }
        }
    }
}
