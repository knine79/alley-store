import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 테스트용 데이터베이스 하네스가 실제로 도는지 확인한다.
///
/// 마이그레이션과 제약(유니크, 외래키)은 흉내로 검증되지 않는다. 진짜 PostgreSQL 을
/// 상대해야 하고, 그러려면 스키마를 올리고 되돌리는 이 하네스가 먼저 믿을 만해야 한다.
@Suite("테스트 데이터베이스 하네스")
struct MigrationHarnessTests {
    @Test("스키마를 올리면 표를 쓸 수 있다")
    func migrationsCreateUsableSchema() async throws {
        try await withMigratedApp { app in
            let user = User(
                googleSubject: "sub-harness",
                email: "harness@example.com",
                name: "하네스",
                role: .user
            )
            try await user.save(on: app.db)

            let found = try await User.query(on: app.db)
                .filter(\.$email == "harness@example.com")
                .first()
            #expect(found?.name == "하네스")
        }
    }

    @Test("유니크 제약이 실제로 걸려 있다")
    func uniqueConstraintIsEnforced() async throws {
        // 코드에서 중복을 검사해도 조회와 저장 사이에 다른 요청이 끼어들 수 있다.
        // 최종 방어선이 데이터베이스에 실제로 있는지 확인한다.
        try await withMigratedApp { app in
            try await User(
                googleSubject: "sub-a",
                email: "dup@example.com",
                name: "먼저",
                role: .user
            ).save(on: app.db)

            await #expect(throws: (any Error).self) {
                try await User(
                    googleSubject: "sub-b",
                    email: "dup@example.com",
                    name: "나중",
                    role: .user
                ).save(on: app.db)
            }
        }
    }

    @Test("되돌리기가 남긴 것을 지운다")
    func revertCleansUp() async throws {
        try await withMigratedApp { app in
            try await User(
                googleSubject: "sub-leftover",
                email: "leftover@example.com",
                name: "잔재",
                role: .user
            ).save(on: app.db)
        }

        // 앞 블록이 끝나면서 되돌려졌으므로 다음 블록은 빈 상태에서 시작해야 한다.
        // 여기서 실패하면 테스트끼리 서로의 데이터를 보게 된다.
        try await withMigratedApp { app in
            let count = try await User.query(on: app.db).count()
            #expect(count == 0)
        }
    }
}
