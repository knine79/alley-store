import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱에 버전을 올릴 수 있는 사람.
///
/// 앱 등록은 developer 역할이면 누구나 할 수 있지만, 남의 앱에 버전을 올리는 것은
/// 다르다. 조직 구성원 전체가 설치하게 될 바이너리라서 앱 단위로 다시 좁힌다.
/// 오너는 이 표에 없어도 항상 올릴 수 있다.
public final class AppMember: Model, @unchecked Sendable {
    public static let schema = "app_members"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "app_id")
    public var app: App

    @Parent(key: "user_id")
    public var user: User

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(id: UUID? = nil, appID: UUID, userID: UUID) {
        self.id = id
        self.$app.id = appID
        self.$user.id = userID
    }
}

// MARK: - 마이그레이션

public struct CreateAppMember: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(AppMember.schema)
            .id()
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            // 같은 사람을 두 번 넣어도 권한이 늘지 않는다. 행만 지저분해진다.
            .unique(on: "app_id", "user_id")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(AppMember.schema).delete()
    }
}
