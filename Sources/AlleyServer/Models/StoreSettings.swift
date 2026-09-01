import AlleyShared
import Fluent
import Foundation
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
        allowsAnonymousFeedback: Bool = true
    ) {
        self.id = Self.singletonID
        self.storeName = storeName
        self.logoURL = logoURL
        self.accentColor = accentColor
        self.allowedEmailDomains = allowedEmailDomains
        self.bundleIDPrefix = bundleIDPrefix
        self.enforceBundleIDPrefix = enforceBundleIDPrefix
        self.allowsAnonymousFeedback = allowsAnonymousFeedback
    }
}

extension StoreSettings {
    /// 클라이언트 부트스트랩용 메타 정보로 변환한다.
    ///
    /// 커스텀 URL 스킴은 설정이 아니라 환경변수에서 온다. 스토어 앱의 `Info.plist`
    /// 에 박히는 값이라 서버 혼자 바꾸면 이미 깔린 앱의 로그인이 깨진다.
    public func toMeta(callbackURLScheme: String) -> StoreMeta {
        StoreMeta(
            storeName: storeName,
            logoURL: logoURL,
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
