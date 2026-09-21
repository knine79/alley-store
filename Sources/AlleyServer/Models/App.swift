import AlleyShared
import Fluent
import Foundation
import SQLKit
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

    /// 화면과 스토어 앱이 그리는 아이콘 주소.
    ///
    /// 우리가 받아 보관한 것이면 `/apps/<id>/icon.png?v=...` 이고, 예전처럼 사람이
    /// 적은 외부 주소면 그 값이다. 보는 쪽은 구분할 필요가 없다.
    @OptionalField(key: "icon_url")
    public var iconURL: String?

    /// 그 그림이 스토리지에 놓인 자리. 외부 주소만 적은 앱에는 없다.
    @OptionalField(key: "icon_key")
    public var iconStorageKey: String?

    @OptionalField(key: "category")
    public var category: String?

    /// 번들 ID 가 아직 확정되지 않았다.
    ///
    /// dmg 로 올린 직후가 그렇다. `bundleID` 에는 임시값이 들어 있고, 워커가 번들에서
    /// 읽은 값으로 서버가 바꾼다 (ADR-0034). 확정될 때까지 이 앱은 출시할 수 없다.
    @Field(key: "bundle_id_pending")
    public var bundleIDPending: Bool

    /// 이 앱의 소식을 어디로 보낼지 (ADR-0059).
    ///
    /// 운영 알림과 같은 갈래를 쓴다. 받는 사람만 다르다 - 여기서는 이 앱을 올릴 수
    /// 있는 사람들이다.
    ///
    /// **문자열로 둔다.** 값이 둘뿐이고 enum 타입을 만들면 갈래를 늘릴 때마다
    /// 마이그레이션이 필요하다. 모르는 값은 읽는 쪽이 기본값으로 접는다.
    @Field(key: "alerts")
    public var alertsRaw: String

    /// 모르는 값은 개별 전송으로 접는다. 채널은 등록해 둔 것이 있어야 닿고 개별은
    /// 설정 없이 닿는다. 알 수 없는 상태에서는 닿는 쪽이 맞다.
    public var alerts: AlertDelivery {
        get { AlertDelivery(rawValue: alertsRaw) ?? .people }
        set { alertsRaw = newValue.rawValue }
    }

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
        bundleIDPending: Bool = false,
        alerts: AlertDelivery = .people
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
        self.alertsRaw = alerts.rawValue
    }
}

extension App {
    /// 클라이언트가 보는 형태로 바꾼다.
    ///
    /// 최신 출시본은 조회하는 쿼리가 따로 필요해서 호출자가 넘긴다.
    /// 목록 응답에서 앱마다 별도 쿼리를 돌리면 N+1 이 된다.
    public func toDTO(
        latestReleased: Version? = nil,
        rating: RatingSummary? = nil,
        isStoreApp: Bool = false
    ) throws -> AppDTO {
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
            isStoreApp: isStoreApp ? true : nil,
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

/// 번들에서 꺼낸 아이콘을 보관할 자리 (ADR-0045 와 같은 방식).
///
/// `icon_url` 은 남긴다. 예전처럼 외부 주소를 적은 앱이 있고, 보는 쪽은 그 둘을
/// 구분할 필요가 없다.
public struct AddAppIconKey: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(App.schema)
            .field("icon_key", .string)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(App.schema)
            .deleteField("icon_key")
            .update()
    }
}

/// 앱 소식을 어디로 보낼지 정하는 칸을 만든다 (ADR-0059).
///
/// **이미 도는 앱의 동작을 바꾸지 않는다.** 지금까지 앱 알림은 앱에 붙은 대상(채널)
/// 으로만 갔다. 기본값을 개별 전송으로 깔면, 채널을 걸어두고 그것을 보던 팀이 어느
/// 날부터 채널에서 못 받는다.
///
/// 그래서 붙은 대상이 하나라도 있으면 `channel`, 없으면 `people` 로 채운다. 전자는
/// 지금 하던 그대로이고, 후자는 지금까지 아무 데도 안 가던 경우라 바꿀 동작이 없다.
/// 운영 알림에 같은 칸을 낼 때와 같은 판단이다 (`AddOperationalAlertsSetting`).
public struct AddAppAlertsSetting: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        // 다시 돌려도 되게 둔다. 아래 UPDATE 가 실패하면 이 마이그레이션은 기록되지
        // 않는데 칸은 이미 생겨 있다.
        try await sql.raw(
            """
            ALTER TABLE apps
            ADD COLUMN IF NOT EXISTS alerts text NOT NULL DEFAULT 'people'
            """
        ).run()
        try await sql.raw(
            """
            UPDATE apps SET alerts = 'channel'
            WHERE EXISTS (
                SELECT 1 FROM notification_targets WHERE notification_targets.app_id = apps.id
            )
            """
        ).run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE apps DROP COLUMN IF EXISTS alerts").run()
    }
}
