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
        pages.post(":appID", "deploy-tokens", use: issueDeployToken)
        pages.post(":appID", "deploy-tokens", ":tokenID", "revoke", use: revokeDeployToken)
        pages.post(":appID", "feedback", use: submitFeedback)
        pages.post(":appID", "feedback", ":feedbackID", "delete", use: deleteFeedback)
        pages.post(":appID", "feed-tokens", use: issueFeedToken)
        pages.post(":appID", "feed-tokens", ":tokenID", "revoke", use: revokeFeedToken)
        pages.post(":appID", "notification-targets", use: addNotificationTarget)
        pages.post(
            ":appID", "notification-targets", ":targetID", "delete",
            use: removeNotificationTarget
        )
    }

    // MARK: - 목록

    @Sendable
    func list(request: Request) async throws -> View {
        let user = try request.requireUser()
        let apps = try await App.query(on: request.db).with(\.$owner).sort(\.$name).all()
        let latest = try await App.latestReleasedVersions(on: request.db)

        // 일반 사용자에게는 출시본이 있는 앱만 보인다. 받을 수 없는 앱이 목록에 뜨면
        // 왜 못 받는지 묻게 된다.
        let ratings = try await Feedback.summaries(
            ofApps: apps.map { try $0.requireID() },
            on: request.db
        )
        let rows: [AppRow] = try apps.compactMap { app in
            let appID = try app.requireID()
            let released = latest[appID]
            guard released != nil || user.role.canPublish else { return nil }
            return try AppRow(app: app, latestReleased: released, rating: ratings[appID])
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
        try await renderDetail(on: request, issuedToken: nil)
    }

    /// 상세 화면을 그린다.
    ///
    /// 방금 발급한 토큰이 있으면 함께 넘긴다. 서버는 해시만 갖고 있어서 다음 요청에는
    /// 보여줄 방법이 없다. 그래서 발급 직후에만 이 자리에 실린다.
    func renderDetail(
        on request: Request,
        issuedToken: IssuedDeployToken?,
        issuedFeed: IssuedFeedToken? = nil,
        feedbackError: String? = nil,
        notificationError: String? = nil,
        feedError: String? = nil
    ) async throws -> View {
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

        // 배포 토큰은 앱을 관리하는 사람만 본다. 멤버에게는 있는지조차 알릴 이유가 없다.
        var feedTokens: [DeployTokenRow] = []
        if canManage {
            feedTokens = try await FeedToken.query(on: request.db)
                .filter(\.$app.$id == app.requireID())
                .sort(\.$name)
                .all()
                .map { token in
                    DeployTokenRow(
                        id: token.id?.uuidString ?? "",
                        name: token.name,
                        lastUsed: token.lastUsedAt.map { DateStyle.minute.string(from: $0) },
                        isActive: token.isActive
                    )
                }
        }

        var deployTokens: [DeployTokenRow] = []
        if canManage {
            deployTokens = try await DeployToken.query(on: request.db)
                .filter(\.$app.$id == app.requireID())
                .sort(\.$name)
                .all()
                .map { try DeployTokenRow(token: $0) }
        }

        var targets: [NotificationTargetDTO] = []
        if canManage {
            targets = try await NotificationTarget.query(on: request.db)
                .filter(\.$app.$id == app.requireID())
                .sort(\.$name)
                .all()
                .map { try $0.toDTO() }
        }

        // 실패한 버전은 로그가 있어야 올린 사람이 스스로 고칠 수 있다.
        // 올릴 권한이 없는 사람에게는 보여줄 이유가 없다. 워커 환경이 드러난다.
        let reports = canUpload
            ? try await SigningJob.latestReports(
                ofVersions: versions.map { try $0.requireID() }, on: request.db
            )
            : [:]

        let settings = try await request.storeSettings()
        // 올릴 권한이 있는 사람에게만 보여준다. 받는 사람에게는 쓸 데가 없는 숫자다.
        var downloads: DownloadSummaryRow?
        var perVersion: [UUID: Int] = [:]
        if canUpload {
            let summary = try await DownloadStats.summary(
                ofApp: try app.requireID(), on: request.db
            )
            downloads = DownloadSummaryRow(
                total: summary.total,
                recent: summary.recent,
                people: summary.people,
                recentDays: DownloadStats.recentDays
            )
            perVersion = try await DownloadStats.perVersion(
                ofApp: try app.requireID(), on: request.db
            )
        }

        let feedback = try await FeedbackPresentation.rows(
            ofApp: try app.requireID(),
            viewer: user,
            on: request
        )
        // 받아본 버전에만 남길 수 있다. 남길 곳이 없으면 폼을 띄우지 않는다.
        let reviewable = try await FeedbackPresentation.reviewableVersions(
            ofApp: try app.requireID(),
            viewer: user,
            on: request.db
        )

        return try await request.view.render(
            "app-detail",
            AppDetailContext(
                page: try await request.pageContext(title: app.name),
                app: try AppRow(
                    app: app,
                    latestReleased: nil,
                    rating: try await Feedback.summary(ofApp: app.requireID(), on: request.db)
                ),
                versions: try versions.map { version in
                    try VersionRow(
                        version: version,
                        report: reports[try version.requireID()],
                        downloadCount: perVersion[try version.requireID()]
                    )
                },
                members: members,
                deployTokens: deployTokens,
                issuedToken: issuedToken,
                downloads: downloads,
                feedTokens: feedTokens,
                issuedFeed: issuedFeed,
                feedError: feedError,
                notificationTargets: targets,
                feedback: feedback,
                reviewableVersions: reviewable,
                allowsAnonymousFeedback: settings.allowsAnonymousFeedback,
                feedbackError: feedbackError,
                notificationError: notificationError,
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

    // MARK: - 배포 토큰

    @Sendable
    func issueDeployToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(DeployTokenFormValues.self)
        let created = try await DeployTokenIssuing.issue(
            named: values.name ?? "",
            for: app,
            by: user,
            on: request.db,
            logger: request.logger
        )

        // 리다이렉트하지 않는다. 토큰은 이 응답에만 있고 다시 볼 방법이 없다.
        let view = try await renderDetail(
            on: request,
            issuedToken: IssuedDeployToken(name: created.token.name, value: created.value)
        )
        let response = Response(status: .created)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
    }

    @Sendable
    func revokeDeployToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        guard let tokenID = request.parameters.get("tokenID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "토큰 ID 형식이 올바르지 않습니다.")
        }
        try await DeployTokenIssuing.revoke(
            tokenID,
            ofApp: app,
            by: user,
            on: request.db,
            logger: request.logger
        )
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
    }

    // MARK: - 피드백

    @Sendable
    func submitFeedback(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        let values = try request.content.decode(FeedbackFormValues.self)

        // 폼이 어느 버전에 남기는지 함께 보낸다. 주소에 버전을 박으면 고른 값과
        // 어긋나고, 그걸 맞추려면 스크립트가 필요해진다.
        guard let versionID = values.versionID.flatMap(UUID.init(uuidString:)),
              let version = try await Version.query(on: request.db)
                  .filter(\.$id == versionID)
                  .filter(\.$app.$id == app.requireID())
                  .with(\.$app)
                  .first()
        else {
            throw Abort(.badRequest, reason: "어느 버전에 남길지 고르세요.")
        }

        do {
            let entry = try await FeedbackSubmission.submit(
                SubmitFeedbackRequest(
                    rating: Int(values.rating ?? ""),
                    body: values.body,
                    // 체크박스는 꺼져 있으면 아예 전송되지 않는다.
                    isAnonymous: values.isAnonymous != nil
                ),
                to: version,
                by: user,
                settings: try await request.storeSettings(),
                on: request.db
            )
            await announce(entry, version: version, by: user, on: request)
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderDetail(
                on: request, issuedToken: nil, feedbackError: abort.reason
            )
            return htmlResponse(view, status: abort.status)
        }
        return request.redirect(to: "/apps/\(version.$app.id.uuidString)#feedback")
    }

    @Sendable
    func deleteFeedback(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        guard let feedbackID = request.parameters.get("feedbackID", as: UUID.self),
              let entry = try await Feedback.find(feedbackID, on: request.db),
              entry.$app.id == (try app.requireID())
        else {
            throw Abort(.notFound, reason: "피드백을 찾을 수 없습니다.")
        }

        let isMine = try entry.$user.id == user.requireID()
        let canManage = try app.canManage(user)
        guard isMine || canManage else {
            throw Abort(.forbidden, reason: "이 피드백을 지울 권한이 없습니다.")
        }

        if let key = entry.screenshotKey {
            try? await request.artifactStorage.delete(key: key)
        }
        try await entry.delete(on: request.db)
        if !isMine {
            request.logger.notice(
                "남의 피드백을 지웠습니다 [앱: \(app.bundleID), 지운 사람: \(user.email)]"
            )
        }
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#feedback")
    }

    /// 앱에 붙은 알림 대상에게 알린다.
    private func announce(
        _ entry: Feedback,
        version: Version,
        by user: User,
        on request: Request
    ) async {
        let stars = entry.rating.map { String(repeating: "★", count: $0) } ?? ""
        let who = entry.isAnonymous ? "익명" : user.name
        await request.notifier.notify(
            app: version.$app.id,
            message: NotificationMessage(
                title: "\(version.app.name) \(version.shortVersion) (\(version.buildNumber)) 에 새 피드백",
                body: [stars, entry.body, "— \(who)"]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                link: request.consoleLink("/apps/\(version.$app.id.uuidString)")
            )
        )
    }

    // MARK: - 피드 토큰

    @Sendable
    func issueFeedToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(DeployTokenFormValues.self)
        do {
            let created = try await FeedTokenIssuing.issue(
                named: values.name ?? "",
                for: app,
                by: user,
                baseURL: request.application.alleyConfig.publicBaseURL,
                on: request.db,
                logger: request.logger
            )
            // 피드 주소에 토큰이 들어 있다. 이 화면을 벗어나면 다시 볼 수 없다.
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                issuedFeed: IssuedFeedToken(name: created.token.name, feedURL: created.feedURL)
            )
            return htmlResponse(view, status: .created)
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderDetail(on: request, issuedToken: nil, feedError: abort.reason)
            return htmlResponse(view, status: abort.status)
        }
    }

    @Sendable
    func revokeFeedToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        guard let tokenID = request.parameters.get("tokenID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "토큰 ID 형식이 올바르지 않습니다.")
        }
        try await FeedTokenIssuing.revoke(
            tokenID, ofApp: app, by: user, on: request.db, logger: request.logger
        )
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
    }

    // MARK: - 알림 대상

    @Sendable
    func addNotificationTarget(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(NotificationTargetFormValues.self)
        do {
            _ = try await NotificationTargets.create(
                CreateNotificationTargetRequest(
                    name: values.name ?? "",
                    endpoint: values.endpoint ?? ""
                ),
                appID: try app.requireID(),
                by: user,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderDetail(
                on: request, issuedToken: nil, notificationError: abort.reason
            )
            return htmlResponse(view, status: abort.status)
        }
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
    }

    @Sendable
    func removeNotificationTarget(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        try await NotificationTargets.remove(
            try request.targetID(),
            appID: try app.requireID(),
            on: request.db
        )
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)")
    }

    private func htmlResponse(_ view: View, status: HTTPStatus) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
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
    /// 별점 평균. 아무도 안 남겼으면 nil.
    var ratingAverage: String?
    var ratingCount: Int

    init(app: App, latestReleased: Version?, rating: RatingSummary? = nil) throws {
        self.id = try app.requireID().uuidString
        self.bundleID = app.bundleID
        self.name = app.name
        self.summary = app.summary
        self.details = app.details
        self.category = app.category
        // 목록에서 오너를 함께 읽어두므로 여기서 관계를 만지지 않는다.
        self.ownerEmail = app.$owner.value?.email ?? ""
        self.latestReleasedVersion = latestReleased?.shortVersion
        self.ratingAverage = rating?.displayAverage
        self.ratingCount = rating?.count ?? 0
    }
}

struct VersionRow: Encodable {
    var id: String
    var shortVersion: String
    var buildNumber: Int
    var state: String
    var stateName: String
    var isReleased: Bool
    /// 지금 출시 버튼을 눌러도 되는 상태인지.
    ///
    /// 상태 머신에 물어본다. 화면이 조건을 따로 갖고 있으면 규칙이 바뀔 때 한쪽만
    /// 남아서, 눌리는데 서버가 거절하는 버튼이 된다.
    var canRelease: Bool
    var releaseNotes: String?
    var fileSize: String?
    var createdAt: String
    var failureReason: String?
    /// 서명 워커가 남긴 로그. 실패했을 때만 화면에 편다.
    ///
    /// 단계마다 쌓인다. 실패 메시지 바로 위에 그 직전 단계가 무엇을 하고 있었는지가
    /// 있어야 원인을 찾을 수 있다 (ADR-0023).
    var log: String?
    /// 무엇 때문에 실패했는지 한 줄로. 갈래를 모르면 nil.
    var failureTitle: String?
    /// 무엇을 해야 하는지.
    var failureAdvice: String?
    /// 지원 문의에 적을 코드. 문장 옆에 작게 보여준다.
    var failureCode: String?
    var canRetry: Bool
    /// 이 버전을 받아간 횟수. 셀 수 없으면 nil.
    var downloadCount: Int?
    /// 무엇으로 서명했는지. 업로더가 준 entitlements 의 키를 한 줄씩 늘어놓는다.
    ///
    /// 비밀이 아니다. 앱이 실행되자마자 죽을 때 "권한이 붙긴 했나"를 화면에서 바로
    /// 확인할 수 있어야 한다. 안 올렸으면 nil 이고 화면에 아무것도 나오지 않는다.
    var entitlementKeys: String?

    init(
        version: Version,
        report: SigningJob.Report? = nil,
        downloadCount: Int? = nil
    ) throws {
        self.id = try version.requireID().uuidString
        self.shortVersion = version.shortVersion
        self.buildNumber = version.buildNumber
        self.state = version.state.rawValue
        self.stateName = version.state.displayName
        self.isReleased = version.state.isPubliclyVisible
        self.canRelease = version.state.canTransition(to: .released)
        self.releaseNotes = version.releaseNotes
        self.fileSize = version.bestArtifact?.fileSize.map(ByteCount.humanReadable)
        self.createdAt = DateStyle.day.string(from: version.createdAt ?? Date())
        self.failureReason = version.failureReason
        self.log = report?.log
        // 코드를 그대로 내보내지 않는다. 사람이 읽는 문장과 함께만 보여준다 (ADR-0023).
        self.failureTitle = report?.failureCode.map(SigningFailureGuidance.title)
        self.failureAdvice = report?.failureCode.map(SigningFailureGuidance.whatToDo)
        self.failureCode = report?.failureCode?.rawValue
        self.canRetry = version.state == .failed
        self.downloadCount = downloadCount

        let keys = version.entitlements.map(EntitlementsPlist.keys(of:)) ?? []
        self.entitlementKeys = keys.isEmpty ? nil : keys.joined(separator: "\n")
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
    var deployTokens: [DeployTokenRow]
    var issuedToken: IssuedDeployToken?
    /// 다운로드 요약. 올릴 권한이 없는 사람에게는 nil.
    var downloads: DownloadSummaryRow?
    var feedTokens: [DeployTokenRow]
    var issuedFeed: IssuedFeedToken?
    var feedError: String?
    var notificationTargets: [NotificationTargetDTO]
    var feedback: [FeedbackRow]
    /// 지금 사람이 피드백을 남길 수 있는 버전들. 받아본 것만 들어온다.
    var reviewableVersions: [ReviewableVersion]
    /// 익명 체크박스를 띄울지. 스토어 설정에서 온다.
    var allowsAnonymousFeedback: Bool
    var feedbackError: String?
    var notificationError: String?
    var canUpload: Bool
    var canManage: Bool
}

struct FeedbackFormValues: Codable {
    var versionID: String?
    var rating: String?
    var body: String?
    var isAnonymous: String?
}

extension FeedbackFormValues: Content {}

struct NotificationTargetFormValues: Codable {
    var name: String?
    var endpoint: String?
}

extension NotificationTargetFormValues: Content {}

/// 화면에 그리는 피드백 한 줄.
struct FeedbackRow: Encodable {
    var id: String
    var versionName: String
    var rating: Int?
    /// 별을 문자열로 미리 만든다. 템플릿에서 반복을 돌리는 것보다 읽기 쉽다.
    var stars: String?
    var body: String?
    var screenshotURL: String?
    var authorName: String?
    var isAnonymous: Bool
    var isMine: Bool
    var createdAt: String
    /// 지금 보는 사람이 지울 수 있는지.
    var canDelete: Bool
}

/// 피드백을 남길 수 있는 버전 하나.
struct ReviewableVersion: Encodable {
    var id: String
    var name: String
}

struct DeployTokenFormValues: Codable {
    var name: String?
}

extension DeployTokenFormValues: Content {}

struct DeployTokenRow: Encodable {
    var id: String
    var name: String
    var lastUsed: String?
    var isActive: Bool

    init(id: String, name: String, lastUsed: String?, isActive: Bool) {
        self.id = id
        self.name = name
        self.lastUsed = lastUsed
        self.isActive = isActive
    }

    init(token: DeployToken) throws {
        self.init(
            id: token.id?.uuidString ?? "",
            name: token.name,
            lastUsed: token.lastUsedAt.map { DateStyle.minute.string(from: $0) },
            isActive: token.isActive
        )
    }
}

/// 앱 하나의 다운로드 요약.
struct DownloadSummaryRow: Encodable {
    var total: Int
    var recent: Int
    var people: Int
    var recentDays: Int
}

/// 방금 발급한 피드 주소. 토큰이 그 안에 들어 있다.
struct IssuedFeedToken: Encodable {
    var name: String
    var feedURL: String
}

/// 방금 발급한 토큰. 이 화면을 벗어나면 다시 볼 수 없다.
struct IssuedDeployToken: Encodable {
    var name: String
    var value: String
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
    /// 워커가 살아 있는지는 날짜만으로 알 수 없다. 마지막 접속에는 시각까지 붙인다.
    case minute

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .current
        switch self {
        case .day:
            formatter.dateFormat = "yyyy. M. d."
        case .minute:
            formatter.dateFormat = "yyyy. M. d. HH:mm"
        }
        return formatter.string(from: date)
    }
}
