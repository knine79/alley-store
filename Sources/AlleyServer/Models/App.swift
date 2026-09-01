import AlleyShared
import Fluent
import Foundation
import Vapor

/// 스토어에 등록된 앱 하나.
///
/// 번들 ID가 정체성이다. 조직 안에서 유일해야 하고, 한 번 정하면 바꾸지 않는다.
/// macOS 가 이 값으로 LaunchServices 등록, UserDefaults 도메인, 키체인 접근 그룹,
/// TCC 권한 승인 단위를 결정하기 때문에 바꾸면 사용자에게는 다른 앱이 된다.
public final class App: Model, @unchecked Sendable {
    public static let schema = "apps"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "bundle_id")
    public var bundleID: String

    @Field(key: "name")
    public var name: String

    @OptionalField(key: "summary")
    public var summary: String?

    /// `description` 은 `CustomStringConvertible` 과 겹쳐서 저장 프로퍼티 이름을 달리 둔다.
    @OptionalField(key: "description")
    public var details: String?

    @OptionalField(key: "icon_url")
    public var iconURL: String?

    @OptionalField(key: "category")
    public var category: String?

    /// 앱을 만든 사람. 메타데이터 수정과 멤버 관리 권한을 갖는다.
    @Parent(key: "owner_id")
    public var owner: User

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @Children(for: \.$app)
    public var versions: [Version]

    @Children(for: \.$app)
    public var members: [AppMember]

    public init() {}

    public init(
        id: UUID? = nil,
        bundleID: String,
        name: String,
        summary: String? = nil,
        details: String? = nil,
        iconURL: String? = nil,
        category: String? = nil,
        ownerID: UUID
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.summary = summary
        self.details = details
        self.iconURL = iconURL
        self.category = category
        self.$owner.id = ownerID
    }
}

extension App {
    /// 클라이언트가 보는 형태로 바꾼다.
    ///
    /// 최신 출시본은 조회하는 쿼리가 따로 필요해서 호출자가 넘긴다.
    /// 목록 응답에서 앱마다 별도 쿼리를 돌리면 N+1 이 된다.
    public func toDTO(latestReleased: Version? = nil, rating: RatingSummary? = nil) throws -> AppDTO {
        AppDTO(
            id: try requireID(),
            bundleID: bundleID,
            name: name,
            summary: summary,
            description: details,
            iconURL: iconURL,
            category: category,
            ownerID: $owner.id,
            latestReleasedVersion: try latestReleased?.toDTO(),
            rating: rating,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? createdAt ?? Date()
        )
    }
}

// MARK: - 마이그레이션

public struct CreateApp: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(App.schema)
            .id()
            .field("bundle_id", .string, .required)
            .field("name", .string, .required)
            .field("summary", .string)
            .field("description", .string)
            .field("icon_url", .string)
            .field("category", .string)
            .field("owner_id", .uuid, .required, .references(User.schema, "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // 번들 ID 중복은 애플리케이션에서도 막지만 최종 방어선은 여기다.
            // 동시에 같은 ID 로 두 요청이 들어오면 코드 검사만으로는 못 막는다.
            .unique(on: "bundle_id")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(App.schema).delete()
    }
}
