import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 등록과 수정의 실제 규칙.
///
/// JSON API 와 웹 콘솔 폼이 **같은 코드를 지나야 한다.** 각자 검증을 들고 있으면
/// "API 는 거부하는데 화면은 통과시킨다"가 언제든 생긴다. 번들 ID 처럼 한 번 정하면
/// 못 바꾸는 값에서 그런 일이 나면 되돌릴 방법이 없다.
///
/// HTTP 를 모르는 순수 함수로 두지는 않았다. 실패를 `Abort` 로 던져야 API 는 상태
/// 코드로, 화면은 문장으로 각각 쓸 수 있다.
enum AppRegistration {
    /// 새 앱을 만든다.
    static func create(
        _ payload: CreateAppRequest,
        owner: User,
        settings: StoreSettings,
        on database: any Database,
        logger: Logger
    ) async throws -> App {
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "앱 이름이 비어 있습니다.")
        }

        let bundleID = payload.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateBundleID(bundleID, settings: settings, logger: logger)

        // 형식이 맞아도 이미 쓰는 ID 면 안 된다. 같은 번들 ID 를 가진 앱이 둘이면
        // macOS 쪽에서 어느 쪽이 설치돼 있는지 구분할 방법이 없다.
        try await requireUnusedBundleID(bundleID, on: database)

        let app = App(
            bundleID: bundleID,
            name: name,
            summary: normalized(payload.summary),
            details: normalized(payload.description),
            category: normalized(payload.category),
            ownerID: try owner.requireID()
        )

        do {
            try await app.save(on: database)
        } catch {
            // 위 조회와 저장 사이에 다른 요청이 같은 ID 를 넣었을 수 있다.
            // 유니크 제약이 최종 방어선이고, 여기서 사용자가 읽을 문장으로 바꾼다.
            try await requireUnusedBundleID(bundleID, on: database)
            throw error
        }
        return app
    }

    /// 메타데이터를 고친다. 보낸 항목만 바꾼다.
    ///
    /// 번들 ID 는 여기 없다. 이미 설치된 앱의 정체성이라 바꾸면 다른 앱이 된다.
    static func update(
        _ app: App,
        with payload: UpdateAppRequest,
        on database: any Database
    ) async throws {
        if let name = payload.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "앱 이름이 비어 있습니다.")
            }
            app.name = trimmed
        }
        // 빈 문자열로 지우는 것과 항목을 안 보낸 것을 구분한다.
        if let summary = payload.summary { app.summary = normalized(summary) }
        if let details = payload.description { app.details = normalized(details) }
        if let category = payload.category { app.category = normalized(category) }
        if let iconURL = payload.iconURL {
            app.iconURL = iconURL.isEmpty
                ? nil
                : try StoreSettingsValidation.validatedLogoURL(iconURL)
        }
        try await app.save(on: database)
    }

    // MARK: - 보조

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func requireUnusedBundleID(
        _ bundleID: String,
        on database: any Database
    ) async throws {
        if try await App.query(on: database).filter(\.$bundleID == bundleID).first() != nil {
            throw Abort(.conflict, reason: "번들 ID '\(bundleID)' 는 이미 등록돼 있습니다.")
        }
    }

    private static func validateBundleID(
        _ bundleID: String,
        settings: StoreSettings,
        logger: Logger
    ) throws {
        do {
            try BundleIdentifier.validate(bundleID, requiredPrefix: settings.bundleIDPrefix)
        } catch {
            // `validate` 는 타입이 붙은 오류를 던지므로 error 는 ValidationError 다.
            // 프리픽스는 조직의 정책이라 경고만 하고 넘어가도록 설정할 수 있다.
            // 형식 오류는 정책이 아니라 사실이라 언제나 막는다.
            if case .prefixMismatch = error, !settings.enforceBundleIDPrefix {
                logger.notice("번들 ID 프리픽스 규칙에서 벗어난 등록: \(bundleID)")
                return
            }
            throw Abort(.badRequest, reason: error.description)
        }
    }
}

// MARK: - 조회

extension App {
    /// 이 앱의 버전 목록.
    ///
    /// 올릴 권한이 없는 사람에게는 출시본만 보인다. 준비 중인 버전 번호가 새어나가면
    /// 출시 전에 알려지지 않아야 할 일정이 드러난다.
    func visibleVersions(for user: User, on database: any Database) async throws -> [Version] {
        var query = try Version.query(on: database)
            .filter(\.$app.$id == requireID())
            .with(\.$artifacts)
            .sort(\.$buildNumber, .descending)

        if try await !canUpload(user, on: database) {
            query = query.filter(\.$state == .released)
        }
        return try await query.all()
    }
}

extension App {
    /// 앱마다 가장 높은 빌드 번호의 출시본을 한 번의 쿼리로 모은다.
    ///
    /// 앱마다 따로 조회하면 목록 화면에서 N+1 이 된다.
    static func latestReleasedVersions(on database: any Database) async throws -> [UUID: Version] {
        let released = try await Version.query(on: database)
            .filter(\.$state == .released)
            .with(\.$artifacts)
            .all()

        return released.reduce(into: [:]) { result, version in
            let appID = version.$app.id
            if let current = result[appID], current.buildNumber >= version.buildNumber { return }
            result[appID] = version
        }
    }

    static func latestReleasedVersion(
        ofApp appID: UUID,
        on database: any Database
    ) async throws -> Version? {
        try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .filter(\.$state == .released)
            .sort(\.$buildNumber, .descending)
            .with(\.$artifacts)
            .first()
    }
}
