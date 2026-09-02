import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리자 화면. 스토어 설정, 역할 관리, 서명 워커.
///
/// 규칙은 `AdminOperations` 에 있고 JSON API 와 공유한다. 여기서는 폼에서 온 문자열을
/// 요청 타입으로 옮기는 일만 한다.
struct AdminPagesController: RouteCollection, Sendable {
    /// 워커 화면에 함께 띄우는 최근 서명 잡 수.
    static let recentJobCount = 10

    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("admin")

        pages.get(use: home)
        pages.get("settings", use: settingsForm)
        pages.post("settings", use: submitSettings)
        pages.get("users", use: userList)
        pages.post("users", ":userID", "role", use: submitRole)
        pages.get("workers", use: workerList)
        pages.post("workers", use: registerWorker)
        pages.post("workers", ":workerID", "revoke", use: revokeWorker)
        pages.get("stats", use: stats)
        pages.get("portal", use: portal)
        pages.post("portal", "bundle-ids", use: registerBundleID)
    }

    /// 관리 화면의 첫 장은 설정이다. 역할 관리는 사람이 들어올 때마다 하는 일이 아니다.
    @Sendable
    func home(request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        return request.redirect(to: "/admin/settings")
    }

    // MARK: - 스토어 설정

    @Sendable
    func settingsForm(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        let settings = try await request.storeSettings()
        return try await renderSettings(
            StoreSettingsFormValues(settings: settings),
            error: nil,
            // 저장하고 나면 같은 화면으로 돌아온다. 아무 표시가 없으면 저장이 됐는지
            // 알 수 없어서, 리다이렉트에 붙여둔 표시를 읽어 한 줄 띄운다.
            saved: request.query[String.self, at: "saved"] == "1",
            on: request
        )
    }

    @Sendable
    func submitSettings(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let settings = try await request.storeSettings()
        let values = try request.content.decode(StoreSettingsFormValues.self)

        do {
            try await AdminOperations.updateSettings(
                values.toRequest(),
                of: settings,
                by: admin,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 사용자가 고칠 수 있는 실패다. 오류 화면으로 보내면 적은 값이 날아가고,
            // 무엇을 고쳐야 하는지도 폼에서 멀어진다. 보낸 값을 그대로 채워 다시 그린다.
            let view = try await renderSettings(
                values, error: abort.reason, saved: false, on: request
            )
            return htmlResponse(view, status: abort.status)
        }

        return request.redirect(to: "/admin/settings?saved=1")
    }

    private func renderSettings(
        _ values: StoreSettingsFormValues,
        error: String?,
        saved: Bool,
        on request: Request
    ) async throws -> View {
        try await request.view.render(
            "admin-settings",
            StoreSettingsPageContext(
                page: try await request.pageContext(title: "스토어 설정"),
                values: values,
                error: error,
                saved: saved
            )
        ).get()
    }

    // MARK: - 역할 관리

    @Sendable
    func userList(request: Request) async throws -> View {
        let admin = try request.requireAdmin()
        return try await renderUsers(error: nil, viewedBy: admin, on: request)
    }

    @Sendable
    func submitRole(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let target = try await request.findUser()
        let values = try request.content.decode(RoleFormValues.self)

        guard let role = UserRole(rawValue: values.role) else {
            throw Abort(.badRequest, reason: "알 수 없는 역할입니다: \(values.role)")
        }

        do {
            try await AdminOperations.changeRole(
                of: target,
                to: role,
                by: admin,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 마지막 관리자를 강등하려는 경우가 여기로 온다. 목록을 그대로 두고
            // 왜 안 되는지만 위에 띄운다.
            let view = try await renderUsers(error: abort.reason, viewedBy: admin, on: request)
            return htmlResponse(view, status: abort.status)
        }
        return request.redirect(to: "/admin/users")
    }

    private func renderUsers(
        error: String?,
        viewedBy admin: User,
        on request: Request
    ) async throws -> View {
        let users = try await User.query(on: request.db).sort(\.$email).all()
        let adminID = try admin.requireID()

        return try await request.view.render(
            "admin-users",
            UserListPageContext(
                page: try await request.pageContext(title: "역할 관리"),
                users: try users.map { user in
                    UserRow(user: user, isSelf: try user.requireID() == adminID)
                },
                roles: UserRole.allCases.map { RoleOption(value: $0.rawValue, name: $0.displayName) },
                error: error
            )
        ).get()
    }

    // MARK: - 워커

    @Sendable
    func workerList(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        return try await renderWorkers(issued: nil, error: nil, on: request)
    }

    @Sendable
    func registerWorker(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let values = try request.content.decode(WorkerFormValues.self)

        do {
            let created = try await AdminOperations.registerWorker(
                named: values.name ?? "",
                by: admin,
                on: request.db,
                logger: request.logger
            )
            // 리다이렉트하지 않는다. 토큰은 지금 이 응답에만 있고, 서버는 해시만
            // 갖고 있어서 다음 화면에서 다시 보여줄 방법이 없다.
            let view = try await renderWorkers(issued: created, error: nil, on: request)
            return htmlResponse(view, status: .created)
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderWorkers(issued: nil, error: abort.reason, on: request)
            return htmlResponse(view, status: abort.status)
        }
    }

    @Sendable
    func revokeWorker(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        guard let workerID = request.parameters.get("workerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "워커 ID 형식이 올바르지 않습니다.")
        }

        do {
            try await AdminOperations.revokeWorker(
                workerID,
                by: admin,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderWorkers(issued: nil, error: abort.reason, on: request)
            return htmlResponse(view, status: abort.status)
        }
        return request.redirect(to: "/admin/workers")
    }

    private func renderWorkers(
        issued: CreatedWorker?,
        error: String?,
        on request: Request
    ) async throws -> View {
        let workers = try await Worker.query(on: request.db).sort(\.$name).all()
        // 최근 잡을 함께 보여준다. 멈춘 잡을 큐로 되돌린 사실은 여기서만 보인다.
        // 시도 횟수가 1 보다 크면 누군가 그 잡을 다시 내보냈다는 뜻이다.
        let jobs = try await SigningJob.query(on: request.db)
            .sort(\.$updatedAt, .descending)
            .range(..<Self.recentJobCount)
            .with(\.$version) { $0.with(\.$app) }
            .all()

        return try await request.view.render(
            "admin-workers",
            WorkerListPageContext(
                page: try await request.pageContext(title: "서명 워커"),
                workers: try workers.map { try WorkerRow(worker: $0) },
                jobs: jobs.map { SigningJobRow(job: $0) },
                issued: issued.map { IssuedWorkerToken(name: $0.worker.name, token: $0.token) },
                error: error
            )
        ).get()
    }

    // MARK: - 통계

    /// 무엇이 실제로 쓰이는가.
    ///
    /// 다운로드가 없는 앱도 0 으로 보여준다. 목록에서 사라지면 "아무도 안 받는 앱"이
    /// 안 보이고, 그게 가장 알고 싶은 것 중 하나다.
    @Sendable
    func stats(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        let overview = try await DownloadStats.overview(on: request.db)
        let ratings = try await Feedback.summaries(
            ofApps: overview.rows.map(\.appID),
            on: request.db
        )

        return try await request.view.render(
            "admin-stats",
            StatsPageContext(
                page: try await request.pageContext(title: "통계"),
                recentDays: DownloadStats.recentDays,
                totalDownloads: overview.totalDownloads,
                recentDownloads: overview.recentDownloads,
                activePeople: overview.activePeople,
                apps: overview.rows.map { row in
                    StatsRow(
                        id: row.appID.uuidString,
                        name: row.appName,
                        bundleID: row.bundleID,
                        total: row.total,
                        recent: row.recent,
                        people: row.people,
                        rating: ratings[row.appID]?.displayAverage
                    )
                }
            )
        ).get()
    }

    // MARK: - 개발자 포털

    /// 인증서 만료와 App ID 현황.
    ///
    /// 연동이 없거나 Apple 쪽이 답하지 않아도 화면은 뜬다. 무엇이 잘못됐는지 적어서
    /// 보여주는 것이 이 화면의 절반이다.
    @Sendable
    func portal(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        return try await renderPortal(error: nil, on: request)
    }

    @Sendable
    func registerBundleID(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let values = try request.content.decode(BundleIDFormValues.self)

        do {
            _ = try await PortalRegistration.registerBundleID(
                RegisterBundleIDRequest(
                    identifier: values.identifier ?? "",
                    name: values.name ?? ""
                ),
                using: try request.appStoreConnect(),
                by: admin,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderPortal(error: abort.reason, on: request)
            return htmlResponse(view, status: abort.status)
        } catch {
            let view = try await renderPortal(error: describe(error), on: request)
            return htmlResponse(view, status: .badGateway)
        }
        return request.redirect(to: "/admin/portal")
    }

    private func renderPortal(error: String?, on request: Request) async throws -> View {
        var certificates: [CertificateRow] = []
        var bundleIDs: [ASCBundleID] = []
        var connectionError: String?

        do {
            let client = try request.appStoreConnect()
            certificates = try await client.certificates()
                .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
                .map { CertificateRow(certificate: $0) }
            bundleIDs = try await client.bundleIDs().sorted { $0.identifier < $1.identifier }
        } catch {
            // 연동이 없거나 Apple 이 답하지 않는 경우다. 화면은 그대로 띄우고 이유만 적는다.
            connectionError = describe(error)
        }

        let settings = try await request.storeSettings()
        return try await request.view.render(
            "admin-portal",
            PortalPageContext(
                page: try await request.pageContext(title: "개발자 포털"),
                isConfigured: request.application.alleyConfig.appStoreConnect != nil,
                certificates: certificates,
                bundleIDs: bundleIDs,
                suggestedWildcard: settings.bundleIDPrefix.map { "\($0).*" },
                connectionError: connectionError,
                error: error
            )
        ).get()
    }

    private func describe(_ error: any Error) -> String {
        if let abort = error as? any AbortError { return abort.reason }
        return String(describing: error)
    }

    private func htmlResponse(_ view: View, status: HTTPStatus) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
    }
}

// MARK: - 화면별 데이터

/// 설정 폼이 주고받는 값.
///
/// 전부 문자열인 이유는 HTML 폼이 그것밖에 못 보내기 때문이다. 허용 도메인은
/// 쉼표로 나눈 한 줄로 다룬다. 항목마다 칸을 만들어 추가·삭제 버튼을 다는 것은
/// 스크립트를 요구하는데, 도메인은 조직 하나에 보통 한두 개다.
struct StoreSettingsFormValues: Codable {
    var storeName: String?
    var logoURL: String?
    var accentColor: String?
    var allowedEmailDomains: String?
    var bundleIDPrefix: String?
    /// 체크박스는 꺼져 있으면 아예 전송되지 않는다. 그래서 옵셔널이고 nil 이 곧 꺼짐이다.
    var enforceBundleIDPrefix: String?
    var allowsAnonymousFeedback: String?
    var confirmOpenToAnyDomain: String?

    init(settings: StoreSettings) {
        self.storeName = settings.storeName
        self.logoURL = settings.logoURL
        self.accentColor = settings.accentColor
        self.allowedEmailDomains = settings.allowedEmailDomains.joined(separator: ", ")
        self.bundleIDPrefix = settings.bundleIDPrefix
        self.enforceBundleIDPrefix = settings.enforceBundleIDPrefix ? "on" : nil
        self.allowsAnonymousFeedback = settings.allowsAnonymousFeedback ? "on" : nil
        self.confirmOpenToAnyDomain = nil
    }

    func toRequest() -> UpdateStoreSettingsRequest {
        UpdateStoreSettingsRequest(
            storeName: storeName ?? "",
            logoURL: logoURL ?? "",
            accentColor: accentColor ?? "",
            allowedEmailDomains: (allowedEmailDomains ?? "").split(separator: ",").map(String.init),
            bundleIDPrefix: bundleIDPrefix ?? "",
            // 폼은 화면에 있는 모든 항목을 한 번에 보낸다. 체크가 없으면 껐다는 뜻이다.
            enforceBundleIDPrefix: enforceBundleIDPrefix != nil,
            allowsAnonymousFeedback: allowsAnonymousFeedback != nil,
            confirmOpenToAnyDomain: confirmOpenToAnyDomain != nil
        )
    }
}

extension StoreSettingsFormValues: Content {}

struct StoreSettingsPageContext: Encodable {
    var page: PageContext
    var values: StoreSettingsFormValues
    var error: String?
    var saved: Bool
}

struct RoleFormValues: Codable {
    var role: String
}

extension RoleFormValues: Content {}

struct UserRow: Encodable {
    var id: String
    var email: String
    var name: String
    var role: String
    var roleName: String
    /// 자기 자신인지. 화면에서 표시만 하고 변경을 막지는 않는다.
    /// 마지막 관리자만 아니면 스스로 물러나는 것은 정당한 동작이다.
    var isSelf: Bool

    init(user: User, isSelf: Bool) {
        self.id = user.id?.uuidString ?? ""
        self.email = user.email
        self.name = user.name
        self.role = user.role.rawValue
        self.roleName = user.role.displayName
        self.isSelf = isSelf
    }
}

struct RoleOption: Encodable {
    var value: String
    var name: String
}

struct UserListPageContext: Encodable {
    var page: PageContext
    var users: [UserRow]
    var roles: [RoleOption]
    var error: String?
}

struct WorkerFormValues: Codable {
    var name: String?
}

extension WorkerFormValues: Content {}

struct WorkerRow: Encodable {
    var id: String
    var name: String
    var osVersion: String?
    var lastSeen: String?
    var isBusy: Bool
    var isActive: Bool

    init(worker: Worker) throws {
        self.id = worker.id?.uuidString ?? ""
        self.name = worker.name
        self.osVersion = worker.osVersion
        self.lastSeen = worker.lastSeenAt.map { DateStyle.minute.string(from: $0) }
        self.isBusy = worker.currentJobID != nil
        self.isActive = worker.isActive
    }
}

/// 화면에 뿌리는 서명 잡 한 줄.
///
/// 앱과 버전을 미리 읽어둔 잡을 넘겨야 한다. 안 읽었으면 이름 대신 "?" 가 나간다.
struct SigningJobRow: Encodable {
    var app: String
    var version: String
    var state: String
    /// 몇 번째 시도인지. 1 보다 크면 멈춰서 되돌린 적이 있다는 뜻이다.
    var attempt: Int
    var lastSeen: String?
    /// 실패 이유. 왜 멈췄는지가 여기 남는다.
    var note: String?

    init(job: SigningJob) {
        let version = job.$version.value
        self.app = version?.$app.value?.name ?? "?"
        self.version = version.map { "\($0.shortVersion) (\($0.buildNumber))" } ?? "?"
        self.state = Self.stateName(job.state)
        self.attempt = job.attempt
        self.lastSeen = (job.heartbeatAt ?? job.claimedAt).map { DateStyle.minute.string(from: $0) }
        self.note = job.failureReason
    }

    private static func stateName(_ state: SigningJobState) -> String {
        switch state {
        case .queued: return "대기 중"
        case .running: return "처리 중"
        case .succeeded: return "완료"
        case .failed: return "실패"
        }
    }
}

/// 방금 발급한 토큰. 이 화면을 벗어나면 다시 볼 수 없다.
struct IssuedWorkerToken: Encodable {
    var name: String
    var token: String
}

struct BundleIDFormValues: Codable {
    var identifier: String?
    var name: String?
}

extension BundleIDFormValues: Content {}

/// 화면에 뿌리는 인증서 한 줄.
struct CertificateRow: Encodable {
    var name: String
    var type: String
    var expires: String?
    var daysLeft: Int?
    /// 서명에 쓰는 인증서인지. 이게 만료되면 워커가 멈춘다.
    var isDeveloperID: Bool
    /// 만료됐거나 곧 만료된다. 화면에서 눈에 띄게 한다.
    var needsAttention: Bool

    init(certificate: ASCCertificate) {
        self.name = certificate.name
        self.type = certificate.type
        self.expires = certificate.expiresAt.map { DateStyle.day.string(from: $0) }
        let days = certificate.daysUntilExpiry()
        self.daysLeft = days
        self.isDeveloperID = certificate.isDeveloperID
        // 인증서 갱신은 사람의 손이 여러 번 필요한 일이다. 한 달 전에는 알아야 한다.
        self.needsAttention = certificate.isDeveloperID && (days ?? .max) < 30
    }
}

struct StatsRow: Encodable {
    var id: String
    var name: String
    var bundleID: String
    var total: Int
    var recent: Int
    /// 한 번이라도 받아간 사람 수.
    var people: Int
    var rating: String?
}

struct StatsPageContext: Encodable {
    var page: PageContext
    /// "최근"이 며칠인지. 화면에 그 숫자를 적어야 오해가 없다.
    var recentDays: Int
    var totalDownloads: Int
    var recentDownloads: Int
    var activePeople: Int
    var apps: [StatsRow]
}

struct PortalPageContext: Encodable {
    var page: PageContext
    var isConfigured: Bool
    var certificates: [CertificateRow]
    var bundleIDs: [ASCBundleID]
    /// 스토어 설정의 프리픽스로 만든 와일드카드 제안값.
    var suggestedWildcard: String?
    /// Apple 과 이야기하지 못한 이유.
    var connectionError: String?
    /// 사람이 고칠 수 있는 실패.
    var error: String?
}

struct WorkerListPageContext: Encodable {
    var page: PageContext
    var workers: [WorkerRow]
    var jobs: [SigningJobRow]
    var issued: IssuedWorkerToken?
    var error: String?
}
