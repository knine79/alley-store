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

    /// 번들 ID 가 아직 확정되지 않았다.
    ///
    /// dmg 로 올린 직후가 그렇다. `bundleID` 에는 임시값이 들어 있고, 워커가 번들에서
    /// 읽은 값으로 서버가 바꾼다 (ADR-0034). 확정될 때까지 이 앱은 출시할 수 없다.
    @Field(key: "bundle_id_pending")
    public var bundleIDPending: Bool

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
        ownerID: UUID,
        bundleIDPending: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.summary = summary
        self.details = details
        self.iconURL = iconURL
        self.category = category
        self.$owner.id = ownerID
        // 값을 넣지 않으면 저장할 때 죽는다. Fluent 의 `@Field` 는 기본값이 없다.
        self.bundleIDPending = bundleIDPending
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
            bundleIDPending: bundleIDPending ? true : nil,
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

/// 번들 ID 를 아직 모르는 앱을 표시한다.
///
/// dmg 로 올리면 브라우저가 번들을 열 수 없어 번들 ID 를 미리 알 수 없다. 그렇다고
/// 사람에게 손으로 적게 하면 실제와 어긋날 수 있고, 그건 올린 뒤에야 드러난다
/// (ADR-0034). 그래서 임시 ID 로 앱을 만들어두고 워커가 번들에서 읽은 값으로
/// 확정한다.
///
/// `bundle_id` 를 nullable 로 바꾸지 않는다. 그 칼럼은 앱의 정체성이고 UNIQUE 이며
/// 수많은 조회가 매달려 있다. NULL 을 허용하면 그 조회마다 "없을 수도 있다" 를
/// 다뤄야 한다. 대신 임시값을 넣고 **아직 확정 전이라는 사실을 따로 적는다.**
public struct AddAppBundleIDPending: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(App.schema)
            // 기존 행은 전부 확정된 상태다. `sql` 기본값으로 넣어야 이미 있는 행이
            // NULL 로 남지 않는다.
            .field("bundle_id_pending", .bool, .required, .sql(.default(false)))
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(App.schema)
            .deleteField("bundle_id_pending")
            .update()
    }
}
