import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 목록·상세·등록 화면.
///
/// **폼은 JSON API 를 HTTP 로 다시 부르지 않는다.** 같은 프로세스에서 `AppRegistration`
/// 을 직접 부른다. 자기 자신에게 요청을 보내면 커넥션과 직렬화를 왕복으로 낭비하고,
/// 인증 쿠키를 손으로 다시 실어야 한다.
///
/// HTML 폼은 JSON 을 못 보내고 `PATCH`/`DELETE` 도 못 쓴다. 그래서 화면용 경로는
/// 전부 `POST` 이고, 성공하면 새 주소로 리다이렉트한다(POST-redirect-GET). 그러지
/// 않으면 새로 고침이 같은 요청을 다시 보낸다.
struct AppPagesController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("apps")

        pages.get(use: list)
        // 상수 경로가 파라미터보다 먼저 잡히도록 :appID 앞에 둔다.
        pages.get("new", use: newForm)
        pages.post("new", use: submitNew)
        pages.get(":appID", use: detail)
        pages.post(":appID", "edit", use: submitEdit)
    }

    // MARK: - 목록

    @Sendable
    func list(request: Request) async throws -> View {
        let user = try request.requireUser()
        let apps = try await App.query(on: request.db).with(\.$owner).sort(\.$name).all()
        let latest = try await App.latestReleasedVersions(on: request.db)

        // 일반 사용자에게는 출시본이 있는 앱만 보인다. 받을 수 없는 앱이 목록에 뜨면
        // 왜 못 받는지 묻게 된다.
        let rows: [AppRow] = try apps.compactMap { app in
            let released = latest[try app.requireID()]
            guard released != nil || user.role.canPublish else { return nil }
            return try AppRow(app: app, latestReleased: released)
        }

        return try await request.view.render(
            "apps",
            AppListContext(
                page: try await request.pageContext(title: "앱"),
                apps: rows,
                canRegister: user.role.canPublish
            )
        ).get()
    }

    // MARK: - 등록

    @Sendable
    func newForm(request: Request) async throws -> View {
        _ = try request.requirePublisher()
        let settings = try await request.storeSettings()
        return try await render(
            newFormWith: AppFormValues(),
            error: nil,
            settings: settings,
            on: request
        )
    }

    @Sendable
    func submitNew(request: Request) async throws -> Response {
        let user = try request.requirePublisher()
        let settings = try await request.storeSettings()
        let values = try request.content.decode(AppFormValues.self)

        do {
            let app = try await AppRegistration.create(
                CreateAppRequest(
                    bundleID: values.bundleID ?? "",
                    name: values.name ?? "",
                    summary: values.summary,
                    description: values.description,
                    category: values.category
                ),
                owner: user,
                settings: settings,
                on: request.db,
                logger: request.logger
            )
            return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 사용자가 고칠 수 있는 실패다. 오류 화면으로 보내면 입력한 내용이 날아간다.
            // 적은 값을 그대로 채워 폼을 다시 그린다.
            let view = try await render(
                newFormWith: values,
                error: abort.reason,
                settings: settings,
                on: request
            )
            let response = Response(status: abort.status)
            response.headers.contentType = .html
            response.body = .init(buffer: view.data)
            return response
        }
    }

    private func render(
        newFormWith values: AppFormValues,
        error: String?,
        settings: StoreSettings,
        on request: Request
    ) async throws -> View {
        try await request.view.render(
            "app-new",
            AppFormContext(
                page: try await request.pageContext(title: "새 앱"),
                values: values,
                error: error,
                bundleIDPrefix: settings.bundleIDPrefix,
                enforceBundleIDPrefix: settings.enforceBundleIDPrefix
            )
        ).get()
    }

    // MARK: - 상세

    @Sendable
    func detail(request: Request) async throws -> View {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.$owner.load(on: request.db)

        let canUpload = try await app.canUpload(user, on: request.db)
        let canManage = try app.canManage(user)
        let versions = try await app.visibleVersions(for: user, on: request.db)

        // 출시본이 하나도 없는 앱은 받을 사람에게 보일 이유가 없다.
        guard canUpload || versions.contains(where: { $0.state.isPubliclyVisible }) else {
            throw Abort(.notFound, reason: "앱을 찾을 수 없습니다.")
        }

        var members: [AppMemberDTO] = []
        if canUpload {
            members = try await loadMembers(of: app, on: request.db)
        }

        return try await request.view.render(
            "app-detail",
            AppDetailContext(
                page: try await request.pageContext(title: app.name),
                app: try AppRow(app: app, latestReleased: nil),
                versions: try versions.map { try VersionRow(version: $0) },
                members: members,
                canUpload: canUpload,
                canManage: canManage
            )
        ).get()
    }

    @Sendable
    func submitEdit(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(AppFormValues.self)
        try await AppRegistration.update(
            app,
            with: UpdateAppRequest(
                name: values.name,
                summary: values.summary ?? "",
                description: values.description ?? "",
                category: values.category ?? ""
            ),
            on: request.db
        )
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
    }

    private func loadMembers(of app: App, on database: any Database) async throws -> [AppMemberDTO] {
        let ownerID = app.$owner.id
        let members = try await AppMember.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .with(\.$user)
            .all()

        return try [AppMemberDTO(user: app.owner.toDTO(), isOwner: true)]
            + members
            .filter { $0.$user.id != ownerID }
            .map { AppMemberDTO(user: try $0.user.toDTO(), isOwner: false) }
    }
}

// MARK: - 화면별 데이터

/// 목록과 상세가 함께 쓰는 앱 한 줄.
///
/// `AppDTO` 를 그대로 쓰지 않는 이유는 화면이 필요한 것이 다르기 때문이다. 화면은
/// 오너의 이메일과 사람이 읽는 날짜가 필요하고, `ownerID` 같은 UUID 는 쓸 데가 없다.
struct AppRow: Encodable {
    var id: String
    var bundleID: String
    var name: String
    var summary: String?
    var details: String?
    var category: String?
    var ownerEmail: String
    var latestReleasedVersion: String?

    init(app: App, latestReleased: Version?) throws {
        self.id = try app.requireID().uuidString
        self.bundleID = app.bundleID
        self.name = app.name
        self.summary = app.summary
        self.details = app.details
        self.category = app.category
        // 목록에서 오너를 함께 읽어두므로 여기서 관계를 만지지 않는다.
        self.ownerEmail = app.$owner.value?.email ?? ""
        self.latestReleasedVersion = latestReleased?.shortVersion
    }
}

struct VersionRow: Encodable {
    var id: String
    var shortVersion: String
    var buildNumber: Int
    var state: String
    var stateName: String
    var isReleased: Bool
    var releaseNotes: String?
    var fileSize: String?
    var createdAt: String
    var failureReason: String?

    init(version: Version) throws {
        self.id = try version.requireID().uuidString
        self.shortVersion = version.shortVersion
        self.buildNumber = version.buildNumber
        self.state = version.state.rawValue
        self.stateName = version.state.displayName
        self.isReleased = version.state.isPubliclyVisible
        self.releaseNotes = version.releaseNotes
        self.fileSize = version.bestArtifact?.fileSize.map(ByteCount.humanReadable)
        self.createdAt = DateStyle.day.string(from: version.createdAt ?? Date())
        self.failureReason = version.failureReason
    }
}

/// 폼이 주고받는 값.
///
/// 실패했을 때 사용자가 적은 것을 그대로 되돌려주려고 요청과 응답이 같은 타입을 쓴다.
/// 전부 옵셔널인 이유는 브라우저가 빈 칸도 빈 문자열로 보내고, 폼을 처음 열 때는
/// 아무 값도 없기 때문이다.
struct AppFormValues: Codable {
    var bundleID: String?
    var name: String?
    var summary: String?
    var description: String?
    var category: String?
}

struct AppListContext: Encodable {
    var page: PageContext
    var apps: [AppRow]
    var canRegister: Bool
}

struct AppFormContext: Encodable {
    var page: PageContext
    var values: AppFormValues
    var error: String?
    var bundleIDPrefix: String?
    var enforceBundleIDPrefix: Bool
}

struct AppDetailContext: Encodable {
    var page: PageContext
    var app: AppRow
    var versions: [VersionRow]
    var members: [AppMemberDTO]
    var canUpload: Bool
    var canManage: Bool
}

extension AppFormValues: Content {}

// MARK: - 표시 형식

/// 바이트 수를 사람이 읽는 문자열로.
enum ByteCount {
    static func humanReadable(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// 날짜를 화면에 맞게 미리 문자열로 만든다.
///
/// Leaf 에서 날짜를 다루면 형식이 템플릿마다 갈린다. 서버에서 한 번 정해서 넘긴다.
enum DateStyle {
    case day

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .current
        switch self {
        case .day:
            formatter.dateFormat = "yyyy. M. d."
        }
        return formatter.string(from: date)
    }
}
