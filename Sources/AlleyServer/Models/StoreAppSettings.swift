import AlleyShared
import Fluent
import Foundation
import Vapor

/// 스토어 앱 자신을 무엇으로 지을지 (ADR-0046).
///
/// 행이 하나뿐인 표다. `StoreSettings` 와 같은 꼴이고 같은 이유다.
///
/// **왜 `store_settings` 에 컬럼으로 붙이지 않았나.** 성격이 다르다. 스토어 설정은
/// 바꾸면 다음 요청부터 바로 반영되는 값들이고, 여기 있는 것은 **바꾼다고 아무 일도
/// 일어나지 않는** 값들이다. 번들을 다시 지어 올려야 의미가 생긴다. 한 화면에 섞으면
/// "저장" 버튼 하나가 두 가지 뜻을 갖는다.
///
/// **왜 환경변수가 아닌가.** 예전에는 `STORE_APP_URL_SCHEME` 만 환경변수에 있었고,
/// 거기 붙은 주석은 "서버 혼자 바꾸면 이미 깔린 앱의 로그인이 깨진다" 였다. 그
/// 걱정은 **빌드를 서버가 하지 않을 때** 성립한다. 이제 서버가 번들을 지으므로
/// 서버가 원천이고 빌드가 그것을 따라간다. 대신 다른 종류의 위험이 생겨서
/// (`isLocked` 참고) 잠금을 둔다.
public final class StoreAppSettings: Model, @unchecked Sendable {
    public static let schema = "store_app_settings"

    public static let singletonID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    @ID(key: .id)
    public var id: UUID?

    /// 스토어에 등록된 앱 레코드. 첫 빌드 때 만들어 붙인다.
    ///
    /// 서버가 "어느 앱이 스토어 앱인지" 를 아는 자리다. 이것이 없어서 웹에서
    /// 스토어 앱을 받을 길이 없었다 (이슈 #17).
    @OptionalParent(key: "app_id")
    public var app: App?

    @Field(key: "bundle_id")
    public var bundleID: String

    @Field(key: "app_name")
    public var appName: String

    /// 로그인 콜백이 돌아올 커스텀 URL 스킴.
    @Field(key: "url_scheme")
    public var urlScheme: String

    @Field(key: "minimum_system_version")
    public var minimumSystemVersion: String

    /// CI 가 만든 브랜딩 없는 번들이 놓인 자리. 없으면 지을 수 없다.
    @OptionalField(key: "base_bundle_key")
    public var baseBundleKey: String?

    /// 그 번들이 담고 있는 제품 버전. 화면에 적고, 지을 때 `CFBundleShortVersionString`
    /// 으로 쓴다.
    @OptionalField(key: "base_bundle_version")
    public var baseBundleVersion: String?

    @OptionalField(key: "base_bundle_size")
    public var baseBundleSize: Int?

    @OptionalField(key: "base_bundle_uploaded_at")
    public var baseBundleUploadedAt: Date?

    @OptionalParent(key: "updated_by")
    public var updatedBy: User?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        bundleID: String,
        appName: String,
        urlScheme: String,
        minimumSystemVersion: String = StoreAppSettings.defaultMinimumSystemVersion
    ) {
        self.id = Self.singletonID
        self.bundleID = bundleID
        self.appName = appName
        self.urlScheme = urlScheme
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// `scripts/build-store-app.sh` 의 `LSMinimumSystemVersion` 과 같아야 한다.
    public static let defaultMinimumSystemVersion = "14.0"
}

extension StoreAppSettings {
    /// 이 설정으로 이미 한 번이라도 내보냈는지.
    ///
    /// **번들 ID 를 바꾸면 이미 깔린 앱은 업데이트 대상이 아니라 별개 앱이 된다.**
    /// macOS 가 번들 ID 로 앱을 가리기 때문이다. 사용자 화면에는 같은 이름의 앱이
    /// 둘 보이고, 옛것은 영영 업데이트를 받지 못한다. URL 스킴도 마찬가지로 이미
    /// 깔린 앱의 로그인 콜백을 끊는다.
    ///
    /// 그래서 한 번 내보낸 뒤로는 화면에서 잠그고, 바꾸려면 무슨 일이 일어나는지를
    /// 읽고 한 번 더 말하게 한다. 상태로 저장하지 않고 그때그때 세는 것은 값이
    /// 어긋날 자리를 만들지 않기 위해서다.
    public func hasShipped(on database: any Database) async throws -> Bool {
        guard let appID = $app.id else { return false }
        return try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .count() > 0
    }

    /// 지을 준비가 됐는지. 안 됐으면 무엇이 모자란지 말한다.
    public func missingPieces(iconIsSet: Bool) -> [String] {
        var missing: [String] = []
        if baseBundleKey == nil {
            missing.append("CI 가 만든 스토어 앱 번들을 아직 안 올렸습니다.")
        }
        if !iconIsSet {
            missing.append("앱 아이콘을 아직 안 올렸습니다. 아이콘 없이도 지을 수 있지만 Dock 에 기본 아이콘이 뜹니다.")
        }
        return missing
    }
}

// MARK: - 마이그레이션

public struct CreateStoreAppSettings: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(StoreAppSettings.schema)
            .id()
            .field("app_id", .uuid, .references(App.schema, "id", onDelete: .setNull))
            .field("bundle_id", .string, .required)
            .field("app_name", .string, .required)
            .field("url_scheme", .string, .required)
            .field("minimum_system_version", .string, .required)
            .field("base_bundle_key", .string)
            .field("base_bundle_version", .string)
            .field("base_bundle_size", .int)
            .field("base_bundle_uploaded_at", .datetime)
            .field("updated_by", .uuid, .references(User.schema, "id"))
            .field("updated_at", .datetime)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(StoreAppSettings.schema).delete()
    }
}
