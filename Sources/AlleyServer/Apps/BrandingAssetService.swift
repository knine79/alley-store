import AlleyShared
import Fluent
import Foundation
import Vapor

/// 브랜딩 이미지를 받고 내주는 자리.
///
/// 이미지는 스토리지에 두고 행은 그 자리를 가리킨다. 서버가 파일을 직접 받는 것은
/// ADR-0016 이 피드백 스크린샷에 낸 예외와 같은 이유다. 앱 바이너리와 달리 크기가
/// 두 자릿수 작고, 이 화면을 위해 "자리 받기 → PUT → 통지" 세 단계를 스크립트로
/// 붙이면 ADR-0012 에서 그은 선이 무너진다.
public enum BrandingAssetService {
    /// 받아줄 파일 크기의 상한.
    ///
    /// 1024×1024 PNG 는 보통 수백 KB 다. 8MB 는 사진을 그대로 올린 경우까지 받아주되
    /// 실수로 고른 큰 파일은 막는 선이다. ADR-0016 이 스크린샷에 잡은 값과 같게 둔다.
    public static let maximumUploadSize = 8 * 1024 * 1024

    // MARK: - 올리기

    /// 이미지 한 장을 그 종류의 자리에 놓는다. 이미 있으면 갈아끼운다.
    @discardableResult
    public static func accept(
        kind: BrandingAssetKind,
        data: Data,
        by admin: User?,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws -> BrandingAsset {
        guard !data.isEmpty else {
            throw Abort(.badRequest, reason: "빈 파일입니다.")
        }
        guard data.count <= maximumUploadSize else {
            throw Abort(
                .badRequest,
                reason: "\(kind.label)이 너무 큽니다. \(maximumUploadSize / 1024 / 1024)MB 이하로 올려주세요."
            )
        }

        let size = try PNGInspection.validate(data, rule: kind.sizeRule, label: kind.label)

        // **스토리지에 먼저 올린다.** 행을 먼저 바꾸면 그 뒤 업로드가 실패했을 때
        // 아무것도 없는 자리를 가리키는 행이 남는다. 그 상태는 화면에서 깨진 그림으로만
        // 드러나고 원인을 짐작하기 어렵다. 반대 순서로 실패하면 주인 없는 오브젝트가
        // 하나 남을 뿐이고, 그건 다음 업로드가 덮지 않고 그냥 잊힌다.
        let key = storage.newKey(BrandingAsset.objectKey(kind: kind))
        try await storage.put(data, to: key, contentType: "image/png")

        let existing = try await find(kind: kind, on: database)
        let previousKey = existing?.storageKey

        let asset = existing ?? BrandingAsset(
            kind: kind,
            storageKey: key,
            contentType: "image/png",
            width: size.width,
            height: size.height,
            byteCount: data.count
        )
        asset.storageKey = key
        asset.contentType = "image/png"
        asset.width = size.width
        asset.height = size.height
        asset.byteCount = data.count
        asset.$updatedBy.id = try admin?.requireID()
        try await asset.save(on: database)

        // 옛 오브젝트는 행을 갈아끼운 뒤에 지운다. 여기서 실패해도 새 그림은 이미
        // 보이므로 사람이 기다릴 이유가 없다. 남은 것은 쓰레기일 뿐이다.
        if let previousKey, previousKey != key {
            do {
                try await storage.delete(key: previousKey)
            } catch {
                logger.warning("옛 브랜딩 이미지를 지우지 못했습니다 [키: \(previousKey), 오류: \(error)]")
            }
        }

        logger.notice(
            "브랜딩 이미지를 바꿨습니다 [종류: \(kind.rawValue), 크기: \(size.width)×\(size.height), 관리자: \(admin?.email ?? "-")]"
        )
        return asset
    }

    // MARK: - 지우기

    /// 이 종류의 이미지를 없앤다. 없으면 아무 일도 하지 않는다.
    public static func remove(
        kind: BrandingAssetKind,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws {
        guard let asset = try await find(kind: kind, on: database) else { return }
        let key = asset.storageKey
        try await asset.delete(on: database)
        do {
            try await storage.delete(key: key)
        } catch {
            logger.warning("브랜딩 이미지를 스토리지에서 지우지 못했습니다 [키: \(key), 오류: \(error)]")
        }
        logger.notice("브랜딩 이미지를 지웠습니다 [종류: \(kind.rawValue)]")
    }

    // MARK: - 읽기

    public static func find(
        kind: BrandingAssetKind,
        on database: any Database
    ) async throws -> BrandingAsset? {
        try await BrandingAsset.query(on: database).filter(\.$kind == kind).first()
    }

    /// 지금 올라와 있는 것 전부. 화면이 한 번에 그린다.
    public static func all(on database: any Database) async throws -> [BrandingAssetKind: BrandingAsset] {
        let rows = try await BrandingAsset.query(on: database).all()
        return Dictionary(rows.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
