import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리 > 스토어 앱.
///
/// 다른 앱과 다른 화면을 쓰는 이유는 스토어 앱만 **여기서 지어지기** 때문이다.
/// 나머지 앱은 누군가 만든 번들을 올리는 것이고, 스토어 앱은 이 화면이 설정을 들고
/// 번들을 만든다 (ADR-0046).
struct StoreAppPagesController: RouteCollection, Sendable {
    /// 화면에 함께 띄우는 최근 빌드 수.
    static let recentBuildCount = 10

    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("admin", "store-app")

        pages.get(use: page)
        pages.post("settings", use: submitSettings)
        pages.post("build", use: build)

        // 베이스 번들만 본문이 크다. 이 경로에만 따로 상한을 준다.
        pages.on(
            .POST,
            "base-bundle",
            body: .collect(maxSize: .init(value: StoreAppBuildService.maximumBaseBundleSize)),
            use: uploadBaseBundle
        )
    }

    // MARK: - 화면

    @Sendable
    func page(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        return try await render(
            error: request.query[String.self, at: "error"],
            saved: request.query[String.self, at: "saved"] == "1",
            built: request.query[String.self, at: "built"],
            on: request
        )
    }

    private func render(
        values: StoreAppFormValues? = nil,
        error: String?,
        saved: Bool,
        built: String?,
        on request: Request
    ) async throws -> View {
        let settings = try await request.storeAppSettings()
        let assets = try await BrandingAssetService.all(on: request.db)
        let shipped = try await settings.hasShipped(on: request.db)

        var builds: [StoreAppBuildRow] = []
        if let appID = settings.$app.id {
            builds = try await Version.query(on: request.db)
                .filter(\.$app.$id == appID)
                .sort(\.$buildNumber, .descending)
                .limit(Self.recentBuildCount)
                .all()
                .map(StoreAppBuildRow.init)
        }

        return try await request.view.render(
            "admin-store-app",
            StoreAppPageContext(
                page: try await request.pageContext(adminTab: .storeApp),
                values: values ?? StoreAppFormValues(settings: settings),
                icon: BrandingSlot.rows(for: [.appIcon], assets: assets).first,
                base: StoreAppBaseBundle(settings: settings),
                serverURL: request.application.alleyConfig.publicBaseURL,
                isLocked: shipped,
                blockers: settings.missingPieces(iconIsSet: assets[.appIcon] != nil),
                canBuild: settings.baseBundleKey != nil && !settings.bundleID.isEmpty,
                builds: builds,
                error: error,
                saved: saved,
                built: built,
                appPath: settings.$app.id.map { "/apps/\($0.uuidString)" }
            )
        ).get()
    }

    // MARK: - 설정 저장

    @Sendable
    func submitSettings(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let settings = try await request.storeAppSettings()
        let values = try request.content.decode(StoreAppFormValues.self)

        do {
            try await apply(values, to: settings, by: admin, on: request)
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 적은 값을 되살려 다시 그린다. 오류 화면으로 보내면 적은 것이 날아간다.
            let view = try await render(
                values: values, error: abort.reason, saved: false, built: nil, on: request
            )
            let response = Response(status: abort.status)
            response.headers.contentType = .html
            response.body = .init(buffer: view.data)
            return response
        }
        return request.redirect(to: "/admin/store-app?saved=1")
    }

    private func apply(
        _ values: StoreAppFormValues,
        to settings: StoreAppSettings,
        by admin: User,
        on request: Request
    ) async throws {
        let appName = (values.appName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = (values.bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let urlScheme = (values.urlScheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let minimum = (values.minimumSystemVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appName.isEmpty else {
            throw Abort(.badRequest, reason: "앱 이름이 비어 있습니다.")
        }
        try StoreAppValidation.validateBundleID(bundleID)
        try StoreAppValidation.validateURLScheme(urlScheme)
        try StoreAppValidation.validateSystemVersion(minimum)

        // **바뀌면 안 되는 값이 바뀌려 하는가.** 이미 내보낸 뒤에 번들 ID 를 바꾸면
        // 이미 깔린 앱은 업데이트 대상이 아니라 별개 앱이 된다. 그 사실을 읽고 한 번
        // 더 말하게 한다.
        let identityChanged = settings.bundleID != bundleID || settings.urlScheme != urlScheme
        if identityChanged, try await settings.hasShipped(on: request.db) {
            guard values.confirmIdentityChange != nil else {
                throw Abort(
                    .badRequest,
                    reason: """
                        번들 ID 나 URL 스킴을 바꾸려면 아래 확인을 켜야 합니다. \
                        이미 내보낸 앱이 있어서, 바꾸면 그 앱들은 업데이트를 받지 못하고 \
                        사용자 화면에 같은 이름의 앱이 둘 남습니다.
                        """
                )
            }
            request.logger.warning(
                """
                스토어 앱의 정체성을 바꿉니다 \
                [번들 ID: \(settings.bundleID) → \(bundleID), 스킴: \(settings.urlScheme) → \(urlScheme), \
                관리자: \(admin.email)]
                """
            )
        }

        settings.appName = appName
        settings.bundleID = bundleID
        settings.urlScheme = urlScheme
        settings.minimumSystemVersion = minimum
        settings.$updatedBy.id = try admin.requireID()
        try await settings.save(on: request.db)
    }

    // MARK: - 베이스 번들

    @Sendable
    func uploadBaseBundle(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let settings = try await request.storeAppSettings()
        let form = try request.content.decode(StoreAppBaseBundleForm.self)

        guard let file = form.bundle, file.data.readableBytes > 0 else {
            return Self.back(error: "올릴 zip 을 고르세요.", on: request)
        }
        do {
            try await StoreAppBuildService.acceptBaseBundle(
                version: form.version ?? "",
                data: Data(buffer: file.data),
                settings: settings,
                by: admin,
                storage: request.application.artifactStorage,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError {
            return Self.back(error: abort.reason, on: request)
        }
        return Self.back(error: nil, on: request)
    }

    // MARK: - 짓기

    @Sendable
    func build(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let settings = try await request.storeAppSettings()

        let icon: (png: Data, edge: Int)?
        if let asset = try await BrandingAssetService.find(kind: .appIcon, on: request.db) {
            let png = try await request.application.brandingCache.data(forKey: asset.storageKey) {
                try await request.application.artifactStorage.get(
                    key: asset.storageKey,
                    limit: BrandingAssetService.maximumUploadSize
                )
            }
            icon = (png, asset.width)
        } else {
            icon = nil
        }

        do {
            let result = try await StoreAppBuildService.build(
                settings: settings,
                icon: icon,
                // **서버가 자기 주소를 안다** (ADR-0044). 운영 레포의 설정 파일에
                // 같은 값을 손으로 또 적을 이유가 없다.
                serverURL: request.application.alleyConfig.publicBaseURL,
                by: admin,
                storage: request.application.artifactStorage,
                on: request.db,
                logger: request.logger
            )
            return request.redirect(
                to: "/admin/store-app?built=\(result.shortVersion)%20(\(result.buildNumber))"
            )
        } catch let abort as any AbortError {
            return Self.back(error: abort.reason, on: request)
        }
    }

    /// 화면으로 돌려보낸다. 이유가 있으면 싣는다.
    ///
    /// 파일을 고르는 폼과 버튼 하나짜리 폼이라 되살릴 값이 없다
    /// (`AdminPagesController.back(to:error:on:)` 과 같은 이유).
    private static func back(error: String?, on request: Request) -> Response {
        var components = URLComponents(string: AdminTab.storeApp.path) ?? URLComponents()
        components.queryItems = [
            error.map { URLQueryItem(name: "error", value: $0) } ?? URLQueryItem(name: "saved", value: "1")
        ]
        return request.redirect(to: components.string ?? AdminTab.storeApp.path)
    }
}

// MARK: - 검사

/// 번들에 박히는 값들의 형식 검사.
///
/// **여기서 막지 않으면 서명·공증까지 다 끝난 뒤에 드러난다.** 그때는 다시 만드는 데
/// 공증 대기만큼이 더 들고, 잘못된 번들이 이미 스토어에 한 줄 남는다.
enum StoreAppValidation {
    /// 역-도메인 표기. macOS 가 이 값으로 앱을 가리므로 공백이나 슬래시가 들어가면
    /// LaunchServices 가 등록하지 못한다.
    static func validateBundleID(_ value: String) throws {
        guard !value.isEmpty else {
            throw Abort(.badRequest, reason: "번들 ID 가 비어 있습니다. 예: com.example.alley.store")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              value.contains("."),
              !value.hasPrefix("."), !value.hasSuffix("."),
              !value.contains("..")
        else {
            throw Abort(
                .badRequest,
                reason: "번들 ID 는 영문·숫자·점·하이픈만 쓸 수 있고 점으로 나뉜 형태여야 합니다. 예: com.example.alley.store"
            )
        }
    }

    /// 커스텀 URL 스킴. 로그인 콜백이 이 이름으로 돌아온다.
    ///
    /// 대문자를 막는 이유는 macOS 가 스킴을 소문자로 다루기 때문이다. `MyStore` 로
    /// 적어두면 콜백은 `mystore` 로 오고, 그 차이는 로그인이 안 돌아올 때에야 보인다.
    static func validateURLScheme(_ value: String) throws {
        guard !value.isEmpty else {
            throw Abort(.badRequest, reason: "URL 스킴이 비어 있습니다. 예: alleystore")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              let first = value.first, first.isLetter
        else {
            throw Abort(
                .badRequest,
                reason: "URL 스킴은 소문자와 숫자만 쓸 수 있고 글자로 시작해야 합니다. 예: alleystore"
            )
        }
    }

    /// `14.0` 같은 값. `LSMinimumSystemVersion` 에 그대로 들어간다.
    static func validateSystemVersion(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            throw Abort(.badRequest, reason: "최소 macOS 버전은 14.0 처럼 점으로 나눈 숫자여야 합니다.")
        }
    }
}

// MARK: - 화면에 넘기는 값

struct StoreAppFormValues: Content {
    var appName: String?
    var bundleID: String?
    var urlScheme: String?
    var minimumSystemVersion: String?
    /// 이미 내보낸 뒤에 번들 ID·스킴을 바꾸려면 켜야 한다. 체크박스라 꺼져 있으면
    /// 아예 전송되지 않는다.
    var confirmIdentityChange: String?

    init(settings: StoreAppSettings) {
        self.appName = settings.appName
        self.bundleID = settings.bundleID
        self.urlScheme = settings.urlScheme
        self.minimumSystemVersion = settings.minimumSystemVersion
        self.confirmIdentityChange = nil
    }
}

struct StoreAppBaseBundleForm: Content {
    var version: String?
    var bundle: File?
}

/// 올라와 있는 베이스 번들 한 줄.
struct StoreAppBaseBundle: Encodable {
    var isPresent: Bool
    var version: String?
    var summary: String?

    init(settings: StoreAppSettings) {
        self.isPresent = settings.baseBundleKey != nil
        self.version = settings.baseBundleVersion
        if let size = settings.baseBundleSize {
            let megabytes = Double(size) / 1024 / 1024
            self.summary = String(format: "%.1fMB", megabytes)
        }
    }
}

/// 최근 빌드 표의 한 줄.
struct StoreAppBuildRow: Encodable {
    var id: String
    var shortVersion: String
    var buildNumber: Int
    var state: String
    var stateLabel: String
    var createdAt: DisplayDate?

    init(_ version: Version) {
        self.id = version.id?.uuidString ?? ""
        self.shortVersion = version.shortVersion
        self.buildNumber = version.buildNumber
        self.state = version.state.rawValue
        self.stateLabel = version.state.displayName
        // 방금 지은 것이 목록에 뜨는 화면이라 시각까지 보여준다. 날짜만으로는
        // 오늘 세 번 지었을 때 무엇이 방금 것인지 알 수 없다.
        self.createdAt = version.createdAt.map(DateStyle.minute.display(from:))
    }
}

struct StoreAppPageContext: Encodable {
    var page: PageContext
    var values: StoreAppFormValues
    var icon: BrandingSlot?
    var base: StoreAppBaseBundle
    /// 번들에 박힐 서버 주소. 서버가 자기 것을 안다 (ADR-0044).
    var serverURL: String
    /// 이미 내보낸 적이 있어 번들 ID·스킴을 잠글지.
    var isLocked: Bool
    /// 짓기 전에 사람이 알아야 할 것들.
    var blockers: [String]
    var canBuild: Bool
    var builds: [StoreAppBuildRow]
    var error: String?
    var saved: Bool
    /// 방금 지은 버전. `0.4.0 (3)` 꼴.
    var built: String?
    /// 스토어 앱의 앱 화면. 아직 한 번도 안 지었으면 nil 이다.
    ///
    /// 출시·철회·서명 로그는 여기서 하지 않고 그 화면에서 한다. 스토어 앱도
    /// 다른 앱과 같은 길을 지나가므로 화면을 두 벌 만들 이유가 없다.
    var appPath: String?
}
