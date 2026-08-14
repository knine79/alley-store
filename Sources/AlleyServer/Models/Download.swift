import Fluent
import Foundation
import Vapor

/// 누가 어느 버전을 언제 받아갔는지.
///
/// MVP 수용 기준에 들어 있는 항목이다. 다운로드 URL 을 내주기 **전에** 남긴다.
/// 나중에 남기면 URL 만 받고 이력이 빠지는 경로가 생긴다.
public final class Download: Model, @unchecked Sendable {
    public static let schema = "downloads"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "user_id")
    public var user: User

    @Parent(key: "version_id")
    public var version: Version

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(id: UUID? = nil, userID: UUID, versionID: UUID) {
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
