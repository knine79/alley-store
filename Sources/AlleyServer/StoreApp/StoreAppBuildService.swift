import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// 관리 화면에서 누른 "빌드해서 올리기" 가 하는 일 (ADR-0046).
///
/// ```
/// CI 가 만든 브랜딩 없는 번들  ─┐
///                             ↓
///            설정 + 앱 아이콘 → 서버가 다시 싼다
///                             ↓
///                     버전 하나로 등록 → 서명 잡
///                             ↓
///            기존 워커가 서명·공증 → ready → 관리자가 출시
/// ```
///
/// **새로 만든 것은 가운데 한 칸뿐이다.** 앞은 CI 가 이미 하고 있었고, 뒤는 다른 앱이
/// 지나가던 길을 그대로 쓴다. 워커는 이것이 스토어 앱인지 모르고, 알 필요도 없다.
///
/// 빌드 번호는 서버가 정하고 그 값을 번들에도 박는다. 예전에는 번들의
/// `CFBundleVersion` 을 셸이, 스토어의 빌드 번호를 CLI 가 따로 정해서 두 번째
/// 릴리스부터 "업데이트 있음" 이 풀리지 않았다 (이슈 #18). 정하는 곳이 하나면
/// 어긋날 자리가 없다.
public enum StoreAppBuildService {
    /// 서버가 읽어 들일 베이스 번들의 상한.
    ///
    /// 스토어 앱은 2MB 남짓이다. 여유를 크게 두되, 잘못된 파일 하나로 서버 메모리가
    /// 넘어가지는 않게 한다.
    public static let maximumBaseBundleSize = 256 * 1024 * 1024

    // MARK: - 베이스 번들 받기

    /// CI 가 만든 브랜딩 없는 번들을 받아 보관한다.
    @discardableResult
    public static func acceptBaseBundle(
        version rawVersion: String,
        data: Data,
        settings: StoreAppSettings,
        by admin: User,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws -> StoreAppSettings {
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw Abort(.badRequest, reason: "이 번들이 담고 있는 제품 버전을 적어주세요. 예: 0.3.0")
        }
        guard !data.isEmpty else {
            throw Abort(.badRequest, reason: "빈 파일입니다.")
        }
        guard data.count <= maximumBaseBundleSize else {
            throw Abort(
                .badRequest,
                reason: "번들이 \(maximumBaseBundleSize / 1024 / 1024)MB 를 넘습니다. 올린 파일이 맞는지 확인해주세요."
            )
        }
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            throw Abort(.badRequest, reason: "zip 이 아닙니다. CI 의 '스토어 앱 번들' 산출물을 올려주세요.")
        }

        // **여기서 열어본다.** 잘못된 zip 을 보관했다가 빌드할 때 알게 되면, 그때는
        // 무엇이 문제인지 화면에서 멀다. 워커 릴리스가 같은 이유로 같은 검사를 한다.
        let entries = try ZipArchive.entries(in: data)
        _ = try StoreAppBundleRewriter.topLevelAppName(in: entries)

        let key = storage.newKey("store-app/base-\(UUID().uuidString.lowercased()).zip")
        try await storage.put(data, to: key, contentType: "application/zip")

        let previousKey = settings.baseBundleKey
        settings.baseBundleKey = key
        settings.baseBundleVersion = version
        settings.baseBundleSize = data.count
        settings.baseBundleUploadedAt = Date()
        settings.$updatedBy.id = try admin.requireID()
        try await settings.save(on: database)

        if let previousKey {
            do {
                try await storage.delete(key: previousKey)
            } catch {
                logger.warning("옛 스토어 앱 베이스 번들을 지우지 못했습니다 [키: \(previousKey), 오류: \(error)]")
            }
        }

        logger.notice("스토어 앱 베이스 번들을 받았습니다 [버전: \(version), 관리자: \(admin.email)]")
        return settings
    }

    /// 올려둔 베이스 번들을 비운다.
    ///
    /// 비우면 서버 이미지에 딸려 온 번들로 돌아간다 (ADR-0048). **되돌리는 길이
    /// 이것뿐이다.** 올리는 것은 화면에 있는데 무르는 것은 없어서, 잘못 올린 번들을
    /// 물리려면 `store_app_settings` 의 열 네 개를 손으로 비워야 했다.
    ///
    /// 이미지에 번들이 없는 서버라면 비운 뒤 빌드할 것이 없어진다. 그래도 막지
    /// 않는다. 무엇으로 빌드할지는 다시 정하면 되고, 잘못 올린 것을 그대로 두는
    /// 쪽이 더 나쁘다. 화면이 비우기 전에 어디로 돌아가는지 말한다.
    @discardableResult
    public static func removeBaseBundle(
        settings: StoreAppSettings,
        by admin: User,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws -> StoreAppSettings {
        // 올린 것이 없으면 비울 것도 없다. 버튼을 두 번 눌러도 같은 자리에 선다.
        guard let key = settings.baseBundleKey else { return settings }

        settings.baseBundleKey = nil
        settings.baseBundleVersion = nil
        settings.baseBundleSize = nil
        settings.baseBundleUploadedAt = nil
        settings.$updatedBy.id = try admin.requireID()
        try await settings.save(on: database)

        // 오브젝트는 설정을 비운 뒤에 지운다. 순서를 바꿨다가 저장이 실패하면 설정이
        // 이미 없는 오브젝트를 가리킨 채로 남고, 그 상태에서는 빌드가 안 된다.
        do {
            try await storage.delete(key: key)
        } catch {
            logger.warning("올려둔 스토어 앱 베이스 번들을 스토리지에서 지우지 못했습니다 [키: \(key), 오류: \(error)]")
        }

        logger.notice("올려둔 스토어 앱 베이스 번들을 비웠습니다 [관리자: \(admin.email)]")
        return settings
    }

    /// 빌드에 넣을 앱 아이콘. 안 올렸으면 nil 이고 아이콘 없이 나간다.
    ///
    /// 화면과 운영 CI 가 같은 것을 써야 해서 여기 둔다. 두 곳에서 따로 읽으면
    /// 어느 경로로 빌드했느냐에 따라 아이콘이 달라진다.
    public static func appIcon(on request: Request) async throws -> (png: Data, edge: Int)? {
        guard let asset = try await BrandingAssetService.find(kind: .appIcon, on: request.db) else {
            // 안 올렸으면 제품에 딸려 오는 기본 아이콘으로 빌드한다. 아이콘 없이 나간
            // 스토어 앱은 Dock 에서 흰 종이로 보이고, 그것을 본 사람은 앱이 잘못
            // 깔렸다고 생각한다 (`DefaultBranding`).
            guard let png = DefaultBranding.data(
                for: .appIcon, in: request.application.directory
            ) else { return nil }
            // 크기는 파일에서 읽는다. 여기 숫자를 적어두면 그림을 갈 때 같이 고쳐야
            // 하고, 안 고치면 `.icns` 안의 자리와 실제 크기가 어긋난다.
            let size = try PNGInspection.validate(
                png, rule: BrandingAssetKind.appIcon.sizeRule, label: "기본 앱 아이콘"
            )
            return (png, size.width)
        }
        let png = try await request.application.storedImages.data(forKey: asset.storageKey) {
            try await request.application.artifactStorage.get(
                key: asset.storageKey,
                limit: BrandingAssetService.maximumUploadSize
            )
        }
        return (png, asset.width)
    }

    // MARK: - 빌드

    /// 결과. 화면이 무엇이 생겼는지 말할 수 있어야 한다.
    public struct BuildResult: Sendable {
        public var appID: UUID
        public var versionID: UUID
        public var shortVersion: String
        public var buildNumber: Int
    }

    /// 무엇으로 빌드하는가.
    ///
    /// 올린 것이 있으면 그것을, 없으면 서버 이미지에 딸려 온 것을 쓴다 (ADR-0048).
    public struct BaseBundle: Sendable {
        public var version: String
        /// 사람이 올린 것인가. 아니면 제품에 들어 있던 것이다.
        public var isUploaded: Bool
        var storageKey: String?
    }

    /// 지금 쓸 베이스 번들. 둘 다 없으면 nil.
    public static func baseBundle(
        settings: StoreAppSettings,
        in directory: DirectoryConfiguration
    ) -> BaseBundle? {
        if let key = settings.baseBundleKey {
            return BaseBundle(
                version: settings.baseBundleVersion ?? "0.0.0",
                isUploaded: true,
                storageKey: key
            )
        }
        guard BundledStoreApp.data(in: directory) != nil else { return nil }
        return BaseBundle(version: BundledStoreApp.version, isUploaded: false, storageKey: nil)
    }

    /// 지금 설정으로 번들을 빌드해 버전 하나로 올린다.
    public static func build(
        settings: StoreAppSettings,
        icon: (png: Data, edge: Int)?,
        serverURL: String,
        by admin: User,
        storage: any ArtifactStoring,
        on database: any Database,
        directory: DirectoryConfiguration,
        logger: Logger
    ) async throws -> BuildResult {
        guard let base = baseBundle(settings: settings, in: directory) else {
            throw Abort(
                .badRequest,
                reason: "빌드할 번들이 없습니다. 이 서버 이미지에 스토어 앱이 들어 있지 않고 올려둔 것도 없습니다. 제품 릴리스의 alley-store-app-unsigned.zip 을 올려주세요."
            )
        }

        let app = try await resolveApp(settings: settings, by: admin, on: database, logger: logger)
        let appID = try app.requireID()
        let buildNumber = try await VersionController.nextBuildNumber(ofApp: appID, on: database)
        let shortVersion = base.version

        let baseZip: Data
        if let key = base.storageKey {
            baseZip = try await storage.get(key: key, limit: maximumBaseBundleSize)
        } else {
            // 이미지 안의 것을 쓴다. 바로 위에서 있는 것을 확인했다.
            baseZip = BundledStoreApp.data(in: directory) ?? Data()
        }
        let bundle = try StoreAppBundleRewriter.rewrite(
            baseZip: baseZip,
            branding: StoreAppBundleRewriter.Branding(
                appName: settings.appName,
                bundleID: settings.bundleID,
                urlScheme: settings.urlScheme,
                shortVersion: shortVersion,
                buildNumber: buildNumber,
                minimumSystemVersion: settings.minimumSystemVersion,
                serverURL: serverURL,
                icon: icon
            )
        )

        let version = Version(
            appID: appID,
            shortVersion: shortVersion,
            buildNumber: buildNumber,
            releaseNotes: nil,
            minimumOSVersion: settings.minimumSystemVersion,
            // 서명은 워커가 한다. 서버가 빌드한 것은 언제나 미서명이다.
            uploadKind: .unsigned,
            entitlements: nil,
            createdByID: try admin.requireID()
        )
        try await version.save(on: database)

        let versionID = try version.requireID()
        let key = storage.newKey(
            ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .unsigned)
        )
        try await storage.put(bundle, to: key, contentType: "application/zip")

        try await Artifact(
            versionID: versionID,
            kind: .unsigned,
            storageKey: key,
            sha256: SHA256.hash(data: bundle).map { String(format: "%02x", $0) }.joined(),
            fileSize: Int64(bundle.count)
        ).save(on: database)

        // 다른 앱이 지나가는 길과 같은 자리로 들어간다. 업로드를 서버가 대신 했을
        // 뿐이라 상태도 같은 순서를 밟는다 (ADR-0035).
        try version.transition(to: .uploaded)
        try await version.save(on: database)

        // **스토어 앱만 dmg 로도 나간다** (ADR-0050). 다른 앱은 스토어 앱이 받아서
        // `/Applications` 에 직접 넣으므로 사람이 옮길 일이 없다. 이것만 사람이 손으로
        // 옮기고, 그때 dmg 안의 Applications 별칭이 그 일을 드래그 한 번으로 만든다.
        let job = try await SigningJob.enqueue(
            versionID: versionID, makesDiskImage: true, on: database
        )
        logger.notice(
            """
            스토어 앱을 빌드했습니다 \
            [\(settings.bundleID) \(shortVersion) (\(buildNumber)), 크기: \(bundle.count)바이트, \
            아이콘: \(icon == nil ? "없음" : "있음"), 서명 잡 시도: \(job.attempt)]
            """
        )

        return BuildResult(
            appID: appID,
            versionID: versionID,
            shortVersion: shortVersion,
            buildNumber: buildNumber
        )
    }

    /// 스토어 앱의 앱 레코드를 찾거나 만든다.
    ///
    /// 첫 빌드 때 만들어진다. 관리자가 미리 등록해 둘 필요가 없어야 한다. 그
    /// 절차를 사람에게 맡기면 번들 ID 를 손으로 두 번 적게 되고, 둘이 어긋나면
    /// 스토어 앱이 자기 자신을 못 알아본다.
    static func resolveApp(
        settings: StoreAppSettings,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws -> App {
        if let appID = settings.$app.id, let app = try await App.find(appID, on: database) {
            // 번들 ID 를 바꿨으면 앱 레코드도 따라간다. 화면이 잠금을 풀고 바꾸게
            // 해줬다면 그것이 사람의 뜻이다.
            if app.bundleID != settings.bundleID {
                app.bundleID = settings.bundleID
                app.bundleIDPending = false
            }
            app.name = settings.appName
            try await app.save(on: database)
            return app
        }

        // 같은 번들 ID 로 이미 등록된 앱이 있으면 그것을 쓴다. 손으로 먼저 등록해
        // 둔 경우가 여기다. 새로 만들면 유니크 제약에 걸린다.
        if let existing = try await App.query(on: database)
            .filter(\.$bundleID == settings.bundleID)
            .first()
        {
            settings.$app.id = try existing.requireID()
            try await settings.save(on: database)
            logger.notice("이미 등록된 앱을 스토어 앱으로 잇습니다 [\(settings.bundleID)]")
            return existing
        }

        let app = App(
            bundleID: settings.bundleID,
            name: settings.appName,
            summary: "이 스토어의 앱을 받고 업데이트하는 앱입니다.",
            ownerID: try admin.requireID()
        )
        try await app.save(on: database)
        settings.$app.id = try app.requireID()
        try await settings.save(on: database)

        logger.notice("스토어 앱을 스토어에 등록했습니다 [\(settings.bundleID), 관리자: \(admin.email)]")
        return app
    }
}

// MARK: - 읽기

extension StoreAppSettings {
    /// 설정 행을 읽는다. 없으면 환경변수 초기값으로 한 번 만든다.
    ///
    /// `StoreSettings.loadOrSeed` 와 같은 꼴이다. 환경변수는 최초 1회만 쓰이고,
    /// 행이 생긴 뒤로는 데이터베이스가 진실이다.
    public static func loadOrSeed(
        on database: any Database,
        config: AppConfig,
        logger: Logger
    ) async throws -> StoreAppSettings {
        if let existing = try await find(singletonID, on: database) {
            return existing
        }

        let settings = StoreAppSettings(
            // 번들 ID 프리픽스를 아는 스토어라면 그 아래에 두는 것이 맞다. 모르면
            // 사람이 화면에서 적는다.
            bundleID: config.store.seed.bundleIDPrefix.map { "\($0).store" } ?? "",
            appName: config.store.seed.name,
            urlScheme: config.store.callbackURLScheme
        )

        do {
            try await settings.create(on: database)
            logger.notice("스토어 앱 설정을 환경변수 초기값으로 만들었습니다. 이후 변경은 관리자 화면에서 합니다.")
            return settings
        } catch {
            guard let existing = try await find(singletonID, on: database) else { throw error }
            return existing
        }
    }
}

extension Request {
    public func storeAppSettings() async throws -> StoreAppSettings {
        try await StoreAppSettings.loadOrSeed(
            on: db,
            config: application.alleyConfig,
            logger: logger
        )
    }
}
