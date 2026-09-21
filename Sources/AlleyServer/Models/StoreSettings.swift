import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 관리자가 화면에서 바꿀 수 있는 스토어 설정.
///
/// 행이 하나뿐인 표다. 설정 항목이 늘어날 때마다 컬럼이 늘고, 값은 언제나 한 벌만
/// 존재한다. 여러 벌을 둘 이유가 없어서 ID 를 상수로 고정하고 그 행만 읽고 쓴다.
///
/// **여기 없는 설정도 있다.** 비밀값(스토리지 자격증명, JWT 키, OAuth 시크릿)과
/// 부팅에 필요한 값(데이터베이스 주소)은 환경변수에 남는다. 데이터베이스 주소를
/// 데이터베이스에서 읽을 수는 없고, 비밀값을 관리자 화면에 띄울 이유도 없다.
/// 자세한 경계는 ADR-0011 에 있다.
public final class StoreSettings: Model, @unchecked Sendable {
    public static let schema = "store_settings"

    /// 행이 하나뿐이므로 ID 를 상수로 둔다.
    ///
    /// 이렇게 하면 "설정 행을 어떻게 찾지"라는 질문이 사라진다. 조회는 언제나
    /// 기본키 조회이고, 실수로 두 벌이 생길 여지도 없다.
    public static let singletonID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "store_name")
    public var storeName: String

    @OptionalField(key: "logo_url")
    public var logoURL: String?

    @OptionalField(key: "accent_color")
    public var accentColor: String?

    /// 로그인을 허용할 이메일 도메인. 비어 있으면 도메인 제한을 걸지 않는다.
    @Field(key: "allowed_email_domains")
    public var allowedEmailDomains: [String]

    /// 앱 번들 ID 에 요구할 프리픽스. 비어 있으면 강제하지 않는다.
    @OptionalField(key: "bundle_id_prefix")
    public var bundleIDPrefix: String?

    /// 프리픽스를 어길 때 등록을 막을지, 경고만 할지.
    @Field(key: "enforce_bundle_id_prefix")
    public var enforceBundleIDPrefix: Bool

    /// 피드백을 익명으로 남길 수 있는지.
    ///
    /// 조직마다 답이 다르다. 이름이 붙으면 동료가 만든 앱에 낮은 점수를 주기 어렵고,
    /// 익명이면 오너가 되물을 수 없다. 어느 쪽이 나은지는 그 조직의 문화가 정한다.
    ///
    /// **끄더라도 이미 익명으로 남긴 글은 익명으로 남는다.** 남길 때의 약속을
    /// 나중에 뒤집으면 그 사람이 쓴 것이 다른 뜻이 된다.
    @Field(key: "allows_anonymous_feedback")
    public var allowsAnonymousFeedback: Bool

    /// 운영 알림을 어디로 보낼지.
    ///
    /// 워커가 조용해지거나 인증서가 만료될 때 가는 알림이다. 앱 하나가 아니라
    /// 스토어 전체가 멈추는 종류라 관리자가 받아야 한다.
    ///
    /// **문자열로 둔다.** 값이 둘뿐이고 `signing_job_state` 처럼 enum 타입을 만들면
    /// 갈래를 늘릴 때마다 마이그레이션이 필요하다. 모르는 값이 들어오면 읽는 쪽이
    /// 기본값으로 접는다.
    @Field(key: "operational_alerts")
    public var operationalAlertsRaw: String

    /// 위 값을 갈래로 읽는다. 모르는 값은 개별 전송으로 접는다.
    ///
    /// 접는 쪽을 개별로 두는 이유는, 채널은 등록해 둔 것이 있어야 닿고 개별은
    /// 설정 없이 닿기 때문이다. 알 수 없는 상태에서는 닿는 쪽이 맞다.
    public var operationalAlerts: AlertDelivery {
        get { AlertDelivery(rawValue: operationalAlertsRaw) ?? .people }
        set { operationalAlertsRaw = newValue.rawValue }
    }

    /// 마지막으로 설정을 바꾼 사람. 로그인 도메인처럼 위험한 항목이 있어서
    /// 누가 건드렸는지는 남겨둔다.
    @OptionalParent(key: "updated_by")
    public var updatedBy: User?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        storeName: String,
        logoURL: String? = nil,
        accentColor: String? = nil,
        allowedEmailDomains: [String] = [],
        bundleIDPrefix: String? = nil,
        enforceBundleIDPrefix: Bool = true,
        allowsAnonymousFeedback: Bool = true,
        operationalAlerts: AlertDelivery = .people
    ) {
        self.id = Self.singletonID
        self.storeName = storeName
        self.logoURL = logoURL
        self.accentColor = accentColor
        self.allowedEmailDomains = allowedEmailDomains
        self.bundleIDPrefix = bundleIDPrefix
        self.enforceBundleIDPrefix = enforceBundleIDPrefix
        self.allowsAnonymousFeedback = allowsAnonymousFeedback
        self.operationalAlertsRaw = operationalAlerts.rawValue
    }
}

extension StoreSettings {
    /// 클라이언트 부트스트랩용 메타 정보로 변환한다.
    ///
    /// 커스텀 URL 스킴은 설정이 아니라 환경변수에서 온다. 스토어 앱의 `Info.plist`
    /// 에 박히는 값이라 서버 혼자 바꾸면 이미 깔린 앱의 로그인이 깨진다.
    ///
    /// - Parameters:
    ///   - assets: 올라와 있는 브랜딩 이미지들. 올린 로고가 설정의 로고 주소를 이긴다.
    ///   - publicBaseURL: 이미지 주소를 절대 주소로 만들 밑동. 스토어 앱은 화면에
    ///     그리려고 이 주소를 그대로 여는데, 브라우저와 달리 "지금 보고 있는 서버"
    ///     라는 기준이 없어서 상대 경로를 줄 수 없다.
    public func toMeta(
        callbackURLScheme: String,
        assets: [BrandingAssetKind: BrandingAsset] = [:],
        publicBaseURL: String = ""
    ) -> StoreMeta {
        // 설정값의 끝 슬래시는 사람마다 적는 방식이 다르다. 둘을 그냥 이으면
        // `//branding/…` 이 되고, 그것도 대개는 열리지만 리다이렉트를 한 번 더 탄다.
        let base = publicBaseURL.hasSuffix("/") ? String(publicBaseURL.dropLast()) : publicBaseURL

        func absolute(_ asset: BrandingAsset?) -> String? {
            asset.map { base + $0.versionedPath }
        }

        return StoreMeta(
            storeName: storeName,
            logoURL: absolute(assets[.logo]) ?? logoURL
                ?? base + DefaultBranding.path(for: .logo),
            appIconURL: absolute(assets[.appIcon])
                ?? base + DefaultBranding.path(for: .appIcon),
            accentColor: accentColor,
            allowedEmailDomains: allowedEmailDomains,
            callbackURLScheme: callbackURLScheme,
            allowsAnonymousFeedback: allowsAnonymousFeedback
        )
    }

    public func toDTO() -> StoreSettingsDTO {
        StoreSettingsDTO(
            storeName: storeName,
            logoURL: logoURL,
            accentColor: accentColor,
            allowedEmailDomains: allowedEmailDomains,
            bundleIDPrefix: bundleIDPrefix,
            enforceBundleIDPrefix: enforceBundleIDPrefix,
            allowsAnonymousFeedback: allowsAnonymousFeedback,
            updatedAt: updatedAt
        )
    }
}

// MARK: - 마이그레이션

public struct CreateStoreSettings: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(StoreSettings.schema)
            .id()
            .field("store_name", .string, .required)
            .field("logo_url", .string)
            .field("accent_color", .string)
            .field("allowed_email_domains", .array(of: .string), .required)
            .field("bundle_id_prefix", .string)
            .field("enforce_bundle_id_prefix", .bool, .required)
            .field("updated_by", .uuid, .references(User.schema, "id"))
            .field("updated_at", .datetime)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(StoreSettings.schema).delete()
    }
}

/// 익명 피드백 허용 여부를 담을 자리.
///
/// `CreateStoreSettings` 를 고치지 않고 새로 만든다. 이미 마이그레이션을 돌린
/// 데이터베이스는 그 파일을 다시 읽지 않는다.
public struct AddAnonymousFeedbackSetting: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(StoreSettings.schema)
            // 기본은 허용이다. 이미 도는 스토어의 동작이 갑자기 바뀌지 않아야 한다.
            .field("allows_anonymous_feedback", .bool, .required, .sql(.default(true)))
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(StoreSettings.schema)
            .deleteField("allows_anonymous_feedback")
            .update()
    }
}

/// 운영 알림을 어디로 보낼지 정하는 칸을 만든다.
///
/// **이미 도는 스토어의 동작을 바꾸지 않는다.** 지금까지 운영 알림은 전역 알림
/// 대상(채널)으로만 갔다. 기본값을 관리자 개인으로 깔면, 채널을 등록해 두고 그것을
/// 보던 조직이 어느 날부터 채널에서 못 받는다.
///
/// 그래서 전역 대상이 하나라도 있으면 `channel`, 없으면 `admins` 로 채운다. 전자는
/// 지금 하던 그대로이고, 후자는 지금까지 아무 데도 안 가던 경우라 바꿀 동작이 없다.
public struct AddOperationalAlertsSetting: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        // **다시 돌려도 되게 둔다.** 아래 UPDATE 가 실패하면 이 마이그레이션은
        // 기록되지 않는데 칸은 이미 생겨 있다. 그 상태에서 다시 돌리면 "이미 있다"
        // 로 죽어서, 고칠 것도 없는데 서버가 뜨지 않는다.
        try await sql.raw(
            """
            ALTER TABLE store_settings
            ADD COLUMN IF NOT EXISTS operational_alerts text NOT NULL DEFAULT 'admins'
            """
        ).run()
        // 앱에 묶이지 않은 알림 대상이 전역 대상이다.
        try await sql.raw(
            """
            UPDATE store_settings SET operational_alerts = 'channel'
            WHERE EXISTS (SELECT 1 FROM notification_targets WHERE app_id IS NULL)
            """
        ).run()
    }

    /// 만드는 쪽이 원 SQL 이라 되돌리는 쪽도 그렇게 둔다. 한쪽만 Fluent 로 두면
    /// 칸이 이미 없을 때 `DROP` 이 죽는다. 되돌리기가 죽으면 그 뒤 마이그레이션이
    /// 전부 멈춘다.
    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw(
            "ALTER TABLE store_settings DROP COLUMN IF EXISTS operational_alerts"
        ).run()
    }
}

/// 운영 알림의 "관리자 개인" 을 "개별 전송" 으로 고쳐 부른다 (ADR-0059).
///
/// 앱 알림이 같은 갈래를 쓰게 되면서 값 이름이 관리자만 가리키면 안 맞는다. 담긴 뜻은
/// 그대로다 - 채널로 보내느냐, 받아야 할 사람들에게 한 명씩 보내느냐.
///
/// 옛 값을 읽는 쪽이 `people` 로 접으므로 이 마이그레이션이 늦게 돌아도 동작은 같다.
/// 그래도 고쳐 쓰는 이유는, 데이터베이스에 남은 `admins` 가 화면에 없는 말이 되기
/// 때문이다.
public struct RenameAdminsAlertTarget: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw(
            "UPDATE store_settings SET operational_alerts = 'people' WHERE operational_alerts = 'admins'"
        ).run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw(
            "UPDATE store_settings SET operational_alerts = 'admins' WHERE operational_alerts = 'people'"
        ).run()
    }
}
