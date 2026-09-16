import Fluent
import Foundation
import SQLKit
import Vapor

/// 누가 어느 버전을 언제 받아갔는지.
///
/// MVP 수용 기준에 들어 있는 항목이다. 다운로드 URL 을 내주기 **전에** 남긴다.
/// 나중에 남기면 URL 만 받고 이력이 빠지는 경로가 생긴다.
///
/// **받은 사람을 모를 수 있다.** 스토어 앱을 받는 공개 페이지는 로그인을 요구하지
/// 않는다 (ADR-0049). 거기로 받은 줄은 `user` 가 비어 있다. 이력을 아예 남기지
/// 않는 쪽도 있었지만, 그러면 "몇 번 나갔나" 까지 같이 사라진다. 사람을 모르는
/// 것과 받아간 사실을 모르는 것은 다르다.
public final class Download: Model, @unchecked Sendable {
    public static let schema = "downloads"

    @ID(key: .id)
    public var id: UUID?

    /// 받아간 사람. 공개 페이지로 받았으면 비어 있다.
    @OptionalParent(key: "user_id")
    public var user: User?

    @Parent(key: "version_id")
    public var version: Version

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(id: UUID? = nil, userID: UUID?, versionID: UUID) {
        self.id = id
        self.$user.id = userID
        self.$version.id = versionID
    }
}

// MARK: - 마이그레이션

public struct CreateDownload: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Download.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id"))
            // 다운로드 이력은 감사 기록이다. 버전을 지운다고 조용히 사라지면 안 된다.
            // 받아간 사람이 있는 버전은 삭제 자체가 막히는 편이 맞다.
            .field("version_id", .uuid, .required, .references(Version.schema, "id"))
            .field("created_at", .datetime)
            .create()

        // 통계 화면(Phase 4)이 version_id 로 집계하기 시작하면 인덱스를 붙인다.
        // Fluent 의 스키마 빌더에는 인덱스 API 가 없어서 별도 마이그레이션이 필요하고,
        // 지금 데이터 규모에서는 이득이 없다.
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Download.schema).delete()
    }
}

/// 받은 사람을 모를 수 있게 한다 (ADR-0049).
///
/// 스토어 앱을 받는 공개 페이지에는 세션이 없다. `user_id` 가 `NOT NULL` 이면 그
/// 다운로드는 이력을 남길 자리가 아예 없다.
///
/// **집계는 손대지 않아도 된다.** "몇 명이 받았나" 는 `COUNT(DISTINCT user_id)` 로
/// 세는데 PostgreSQL 의 집계 함수는 NULL 을 빼고 센다. 익명 줄이 사람 수를 부풀리지
/// 않는다. "몇 번 나갔나" 는 `COUNT(*)` 라 그대로 늘어난다. 둘 다 원하는 대로다.
/// Fluent 의 스키마 빌더에는 `NOT NULL` 을 떼는 방법이 없어서 SQL 을 직접 쓴다.
/// 이 레포가 이미 여러 자리에서 쓰는 길이다 (`AddIssuerToUser`, `SigningJob`).
public struct MakeDownloadUserOptional: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE downloads ALTER COLUMN user_id DROP NOT NULL").run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        // **익명 줄을 지우고 되돌린다.** `NOT NULL` 을 다시 걸려면 그 줄들이 없어야
        // 한다. 감사 기록을 버리는 일이라 조용히 하지 않고 로그로 남긴다. 되돌릴
        // 일이 생겼다는 것은 공개 페이지를 접었다는 뜻이고, 그때 그 줄들은 가리킬
        // 사람이 없는 기록이다.
        let removed = try await Download.query(on: database).filter(\.$user.$id == nil).count()
        if removed > 0 {
            database.logger.warning("익명 다운로드 이력 \(removed)건을 지우고 되돌립니다.")
            try await Download.query(on: database).filter(\.$user.$id == nil).delete()
        }
        try await sql.raw("ALTER TABLE downloads ALTER COLUMN user_id SET NOT NULL").run()
    }
}
