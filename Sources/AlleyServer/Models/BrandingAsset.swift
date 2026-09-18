import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리자가 올린 브랜딩 이미지 한 장.
///
/// 종류마다 한 장씩이다. 로고를 두 장 둘 이유가 없어서 `kind` 에 유니크를 건다.
///
/// **왜 설정 표에 컬럼으로 붙이지 않았나.** `store_settings` 는 요청마다 읽힌다
/// (`Request.storeSettings()`). 거기에 이미지 자리를 붙이면 화면 한 장을 그릴 때마다
/// 쓰지도 않을 값이 딸려 온다. 스토리지 키만 붙이는 방법도 있었지만, 그러면 크기와
/// 올린 사람 같은 딸린 값이 갈 곳이 없어 결국 컬럼이 늘어난다.
///
/// **이미지 자체는 여기 없다.** 스토리지에 있고 이 행은 그 자리를 가리킨다.
/// 서버가 직접 받아 넣는 것은 ADR-0016 이 스크린샷에 낸 예외와 같은 이유다.
public final class BrandingAsset: Model, @unchecked Sendable {
    public static let schema = "branding_assets"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "kind")
    public var kind: BrandingAssetKind

    /// 스토리지에서의 자리. 바뀔 때마다 새 키를 쓴다(아래 `objectKey` 참고).
    @Field(key: "storage_key")
    public var storageKey: String

    @Field(key: "content_type")
    public var contentType: String

    @Field(key: "width")
    public var width: Int

    @Field(key: "height")
    public var height: Int

    @Field(key: "byte_count")
    public var byteCount: Int

    /// 누가 올렸는지. 로고가 갑자기 바뀌면 물어볼 곳이 있어야 한다.
    @OptionalParent(key: "updated_by")
    public var updatedBy: User?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        kind: BrandingAssetKind,
        storageKey: String,
        contentType: String,
        width: Int,
        height: Int,
        byteCount: Int
    ) {
        self.kind = kind
        self.storageKey = storageKey
        self.contentType = contentType
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }

    /// **새로** 올리는 이미지가 놓일 자리.
    ///
    /// 바꿀 때마다 UUID 를 새로 뽑는다. 같은 키를 덮어쓰면 스토리지와 CDN 의 캐시가
    /// 옛 그림을 한동안 더 내주고, 그 사이 무엇이 보일지 아무도 모른다. 새 키는
    /// 그런 상태 자체를 만들지 않는다. 옛 오브젝트는 행을 갈아끼운 뒤에 지운다.
    public static func objectKey(kind: BrandingAssetKind) -> String {
        "branding/\(kind.rawValue)-\(UUID().uuidString.lowercased()).png"
    }
}

extension BrandingAsset {
    /// 캐시를 지나치게 하는 표시가 붙은 공개 주소.
    ///
    /// 그림을 바꾸면 `updated_at` 이 바뀌고 주소도 바뀐다. 브라우저는 처음 보는
    /// 주소라 다시 받아간다. 정적 파일에 `?v=` 를 붙이는 것(`AssetVersion`)과 같은
    /// 방법이고, 같은 이유다.
    public var versionedPath: String {
        let stamp = updatedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return "\(kind.publicPath)?v=\(stamp)"
    }
}

// MARK: - 종류

/// 브랜딩 이미지가 쓰이는 자리.
///
/// 자리마다 요구하는 크기가 다르다. 파비콘은 16px 로 줄어들고 앱 아이콘은 Dock 에서
/// 1024px 까지 커진다. 한 장으로 둘 다 쓰면 한쪽이 반드시 나빠진다.
public enum BrandingAssetKind: String, Codable, Sendable, CaseIterable {
    /// 브라우저 탭에 뜨는 그림.
    case favicon
    /// 웹 콘솔 머리와 스토어 앱 로그인 화면에 뜨는 그림.
    case logo
    /// 스토어 앱 번들에 `.icns` 로 들어가는 그림 (ADR-0046).
    case appIcon = "app-icon"

    /// 화면에 적는 이름. 실패 문구와 폼 라벨이 한 곳에서 나온다.
    public var label: String {
        switch self {
        case .favicon: "파비콘"
        case .logo: "로고"
        case .appIcon: "앱 아이콘"
        }
    }

    /// 이 자리가 요구하는 크기.
    ///
    /// 파비콘과 로고는 브라우저가 알아서 줄여 그리니 하한만 본다. 앱 아이콘만
    /// 딱 맞아야 하는데, `.icns` 에는 정해진 크기의 자리만 있고 서버는 그림을
    /// 줄이지 못하기 때문이다 (`ICNSWriter`).
    ///
    /// **로고 하한은 64px 이었다.** 줄여 그리는 것만 생각한 값이다. 그런데 로그인
    /// 화면은 로고를 96px 자리에 놓고, 배율 화면에서는 그 두세 배가 필요하다. 64px
    /// 짜리를 올린 스토어에서 그 자리가 흐릿하게 늘어났다. 권하는 값이 이미 512px
    /// 이니 하한도 늘려 그리지 않을 만큼은 받는다.
    public var sizeRule: BrandingSizeRule {
        switch self {
        case .favicon: .atLeast(32)
        case .logo: .atLeast(256)
        case .appIcon: .exactly(ICNSWriter.acceptedEdges)
        }
    }

    /// 권하는 한 변의 길이. 화면 안내에만 쓴다.
    public var recommendedEdge: Int {
        switch self {
        case .favicon: 512
        case .logo: 512
        case .appIcon: 1024
        }
    }

    /// 이 종류를 내주는 공개 경로.
    ///
    /// 로그인 전에도 보여야 한다. 파비콘은 로그인 화면의 탭에도 뜨고, 앱 아이콘은
    /// 스토어 앱이 `/api/v1/meta` 로 받아간 주소를 그대로 연다.
    public var publicPath: String {
        "/branding/\(rawValue).png"
    }
}

// MARK: - 마이그레이션

public struct CreateBrandingAsset: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(BrandingAsset.schema)
            .id()
            .field("kind", .string, .required)
            .field("storage_key", .string, .required)
            .field("content_type", .string, .required)
            .field("width", .int, .required)
            .field("height", .int, .required)
            .field("byte_count", .int, .required)
            .field("updated_by", .uuid, .references(User.schema, "id"))
            .field("updated_at", .datetime)
            // 종류마다 한 장이다. 두 장이 되면 어느 것을 내줄지 정할 방법이 없다.
            .unique(on: "kind")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(BrandingAsset.schema).delete()
    }
}
