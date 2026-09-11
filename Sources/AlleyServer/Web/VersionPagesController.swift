import AlleyShared
import Fluent
import Foundation
import Vapor

/// 버전 업로드 화면과 출시·철회 버튼.
///
/// **업로드만 브라우저에서 JSON API 를 부른다.** 나머지 화면은 폼을 서버가 받지만,
/// 업로드는 바이너리가 서버를 거치지 않고 스토리지로 직접 가야 해서(ADR-0009)
/// 브라우저가 세 단계를 직접 밟는다. 자세한 이유는 ADR-0012 에 있다.
///
/// 출시와 철회는 폼 하나짜리 `POST` 다. 스크립트를 쓸 이유가 없다.
struct VersionPagesController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("apps", ":appID", "versions")

        pages.get("new", use: newForm)
        pages.get(":versionID", "confirm", use: confirmForm)
        pages.post(":versionID", "confirm", use: submitConfirm)
        pages.post(":versionID", "release", use: release)
        pages.post(":versionID", "unrelease", use: unrelease)
        pages.post(":versionID", "retry", use: retry)
    }

    // MARK: - 올린 뒤 확인 화면

    /// 방금 올린 것이 무엇인지 보여주고 이름·설명을 받는다.
    ///
    /// dmg 는 브라우저가 열 수 없어서 올리기 전에는 번들 ID 밖에 물어보지 않는다
    /// (ADR-0033). 실제 버전과 최소 macOS 는 워커가 번들에서 읽어 보고해야 알 수 있고,
    /// 그것을 기다렸다가 여기서 함께 보여준다.
    ///
    /// 화면은 서버가 한 번 그리고, 값이 도착할 때까지는 브라우저가
    /// `GET /api/v1/versions/:id` 를 폴링한다. 워커가 몇 초에서 몇 분 걸리는데 그동안
    /// 사람이 새로고침을 눌러야 한다면 화면이 있으나 마나다.
    @Sendable
    func confirmForm(request: Request) async throws -> View {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        let version = try await request.findVersion()
        let appID = try app.requireID()
        let settings = try await request.storeSettings()
        return try await request.view.render(
            "version-confirm",
            VersionConfirmContext(
                page: try await request.pageContext(title: "올린 것 확인"),
                appID: appID.uuidString,
                appName: app.name,
                bundleID: app.bundleIDPending ? "" : app.bundleID,
                bundleIDPending: app.bundleIDPending,
                bundleIDPrefix: settings.bundleIDPrefix,
                enforceBundleIDPrefix: settings.enforceBundleIDPrefix,
                summary: app.summary ?? "",
                description: app.details ?? "",
                category: app.category ?? "",
                versionID: try version.requireID().uuidString,
                versionPath: APIPath.version(try version.requireID())
            )
        ).get()
    }

    /// 확인 화면에서 받은 이름·설명을 저장한다.
    @Sendable
    func submitConfirm(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(AppFormValues.self)
        if let name = values.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            app.name = name
        }
        app.summary = blankToNil(values.summary)
        app.details = blankToNil(values.description)
        app.category = blankToNil(values.category)
        try await app.save(on: request.db)

        return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
    }

    private func blankToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - 업로드 화면

    @Sendable
    func newForm(request: Request) async throws -> View {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        let appID = try app.requireID()
        return try await request.view.render(
            "version-new",
            VersionFormContext(
                page: try await request.pageContext(title: "새 버전"),
                appID: appID.uuidString,
                appName: app.name,
                appBundleID: app.bundleIDPending ? "" : app.bundleID,
                // 다음 빌드 번호를 미리 채워준다. 같은 번호를 쓰면 서버가 거절하는데,
                // 마지막 번호가 몇이었는지 확인하러 목록으로 돌아가게 할 이유가 없다.
                suggestedBuildNumber: try await nextBuildNumber(ofApp: appID, on: request.db),
                createVersionPath: APIPath.versions(ofApp: appID),
                versionRootPath: "\(APIPath.apiRoot)/versions"
            )
        ).get()
    }

    private func nextBuildNumber(ofApp appID: UUID, on database: any Database) async throws -> Int {
        let highest = try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .sort(\.$buildNumber, .descending)
            .first()
        return (highest?.buildNumber ?? 0) + 1
    }

    // MARK: - 출시 / 철회

    @Sendable
    func release(request: Request) async throws -> Response {
        try await changeRelease(on: request) { version in
            // 번들 ID 가 확정되지 않은 앱은 출시할 수 없다 (ADR-0034).
            //
            // 스토어 앱은 `CFBundleIdentifier` 로 설치 여부를 판단한다. 임시값인 채로
            // 내보내면 받은 사람의 맥에서 영영 "설치 안 됨" 으로 남고, 업데이트도
            // 잡히지 않는다. 받아간 뒤에 고쳐도 이미 나간 것은 되돌릴 수 없다.
            guard !version.app.bundleIDPending else {
                throw Abort(
                    .conflict,
                    reason: """
                        번들 ID 가 아직 확정되지 않아 출시할 수 없습니다. 서명 워커가 \
                        번들을 열어 번들 ID 를 읽어야 확정됩니다. 서명이 실패했다면 \
                        고친 뒤 다시 올리세요.
                        """
                )
            }
            try version.transition(to: .released)
        }
    }

    /// 출시 철회. 배포 가능하지만 비공개인 `ready` 로 돌아간다.
    ///
    /// 아티팩트는 지우지 않는다. 이미 받아간 사람의 앱은 계속 동작하고,
    /// 문제가 해결되면 다시 출시할 수 있어야 한다.
    @Sendable
    func unrelease(request: Request) async throws -> Response {
        try await changeRelease(on: request) { version in
            try version.transition(to: .ready)
            version.releasedAt = nil
        }
    }

    // MARK: - 재시도

    /// 실패한 버전을 다시 서명 큐에 넣는다.
    ///
    /// 올린 바이너리는 그대로 두고 상태만 되돌린다. 서명이 실패하는 이유는 대개 워커
    /// 쪽 환경(인증서 만료, 공증 자격증명)이라, 고친 뒤 같은 파일로 다시 시도하는 것이
    /// 자연스럽다. 파일 자체가 문제였다면 새 빌드를 올리면 된다.
    ///
    /// **entitlements 를 함께 받는다.** 권한이 모자라 실패한 경우에만 화면에 그 칸이
    /// 나온다. 올릴 때는 묻지 않는다 (ADR-0036).
    @Sendable
    func retry(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let version = try await request.findVersion()
        try await version.app.requireUploadAccess(for: user, on: request.db)

        guard let appID = request.parameters.get("appID", as: UUID.self),
              version.$app.id == appID
        else {
            throw Abort(.notFound, reason: "버전을 찾을 수 없습니다.")
        }
        guard version.state == .failed else {
            throw Abort(
                .conflict,
                reason: "실패한 버전만 다시 시도할 수 있습니다. 현재 상태: \(version.state.rawValue)"
            )
        }

        if let attached = try Self.attachedEntitlements(from: request) {
            version.entitlements = attached
        }
        try version.transition(to: .uploaded)
        try await version.save(on: request.db)

        // 다시 시도하는 것도 워커를 거친다. 이미 서명·공증된 번들이면 워커가 그
        // 단계를 건너뛴다 (ADR-0035).
        try await SigningJob.enqueue(versionID: try version.requireID(), on: request.db)
        return request.redirect(to: "/apps/\(appID.uuidString)")
    }

    /// 재시도 폼이 함께 보낸 entitlements plist. 안 붙였으면 nil 이고 원래 값을 둔다.
    ///
    /// 파일 칸이 없는 재시도는 본문이 비어 있다. `multipart` 일 때만 열어본다.
    private static func attachedEntitlements(from request: Request) throws -> String? {
        guard request.headers.contentType?.type == "multipart" else { return nil }

        let form = try request.content.decode(RetryForm.self)
        guard let file = form.entitlements, file.data.readableBytes > 0 else { return nil }
        guard let text = file.data.getString(
            at: file.data.readerIndex, length: file.data.readableBytes
        ) else {
            throw Abort(
                .badRequest,
                reason: "entitlements 파일이 UTF-8 텍스트가 아닙니다. XML plist 여야 합니다."
            )
        }
        return try VersionController.checkedEntitlements(text)
    }

    private func changeRelease(
        on request: Request,
        apply: (Version) throws -> Void
    ) async throws -> Response {
        let user = try request.requireUser()
        let version = try await request.findVersion()
        try await version.app.requireUploadAccess(for: user, on: request.db)

        // 주소의 앱과 버전이 실제로 이어져 있는지 확인한다. 권한은 버전이 속한 앱으로
        // 확인했으므로 이것이 없어도 뚫리지는 않지만, 그러면 남의 앱 주소로 내 버전을
        // 출시한 뒤 엉뚱한 화면으로 돌아가게 된다.
        guard let appID = request.parameters.get("appID", as: UUID.self),
              version.$app.id == appID
        else {
            throw Abort(.notFound, reason: "버전을 찾을 수 없습니다.")
        }

        try apply(version)
        try await version.save(on: request.db)
        return request.redirect(to: "/apps/\(appID.uuidString)")
    }
}

// MARK: - 화면별 데이터

struct VersionFormContext: Encodable {
    var page: PageContext
    var appID: String
    var appName: String
    /// 이 앱의 번들 ID. 브라우저가 **올린 파일이 이 앱이 맞는지** 먼저 본다.
    /// 확정 전이면 빈 문자열이고, 그때는 대조할 것이 없다.
    var appBundleID: String
    var suggestedBuildNumber: Int
    /// 스크립트가 버전을 만들 때 부를 경로.
    var createVersionPath: String
    /// 만든 버전의 완료 통지 경로를 조립할 뿌리. `<root>/<id>/complete` 가 된다.
    var versionRootPath: String
}

/// 올린 뒤 확인 화면에 넘기는 값.
///
/// 버전 값(버전 번호, 최소 macOS)은 여기 없다. 워커가 아직 보고하지 않았을 수 있어서
/// 브라우저가 `versionPath` 를 폴링해 채운다.
/// 재시도할 때 함께 올릴 수 있는 것.
struct RetryForm: Content {
    var entitlements: File?
}

struct VersionConfirmContext: Encodable {
    var page: PageContext
    var appID: String
    var appName: String
    /// 확정 전이면 빈 문자열이다. 임시 ID 는 밖으로 내보내지 않는다.
    var bundleID: String
    var bundleIDPending: Bool
    /// 아직 확정 전이면 무엇을 만족해야 하는지 이 자리에서 알려준다. 규칙을 말하지
    /// 않고 "규칙에 맞아야 합니다" 만 쓰면 알려주는 것이 아니다.
    var bundleIDPrefix: String?
    var enforceBundleIDPrefix: Bool
    var summary: String
    var description: String
    var category: String
    var versionID: String
    /// 브라우저가 값이 올 때까지 폴링할 경로.
    var versionPath: String
}
