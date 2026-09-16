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
        pages.post(":appID", "delete", use: deleteApp)
        pages.post(":appID", "deploy-tokens", use: issueDeployToken)
        pages.post(":appID", "deploy-tokens", ":tokenID", "revoke", use: revokeDeployToken)
        pages.get(":appID", "versions", ":versionID", "download", use: download)
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
        // 등록이 끝나지 않은 앱은 목록에 넣지 않는다.
        //
        // 번들 ID 가 임시값이라 아직 어떤 앱인지 정해지지 않았다. 이름도 파일 이름에서
        // 짐작한 값이다. 그 상태로 목록에 끼면 "확인 중" 이 여럿 늘어서서 무엇이
        // 무엇인지 알 수 없다 (ADR-0034).
        let (settled, unsettled) = try apps.reduce(
            into: ([App](), [App]())
        ) { result, app in
            if app.bundleIDPending {
                result.1.append(app)
            } else {
                result.0.append(app)
            }
        }

        // **스토어 앱은 목록에 넣지 않는다.** 다른 앱을 받는 도구라 같은 줄에 서면
        // 안 된다. 관리는 관리 > 스토어 앱 한 화면에서 끝나고, 받는 것은 아래 안내
        // 한 줄이 맡는다 (ADR-0046).
        let storeAppID = try await request.storeAppSettings().$app.id
        let visibility = try await AppVisibility.of(user, on: request.db)

        let rows: [AppRow] = try settled.compactMap { app in
            let appID = try app.requireID()
            guard appID != storeAppID else { return nil }
            let released = latest[appID]
            // 출시 전인 앱은 손댈 수 있는 사람에게만 보인다 (`AppVisibility`).
            guard try released != nil || visibility.canSeeUnreleased(app) else { return nil }
            return try AppRow(app: app, latestReleased: released, rating: ratings[appID])
        }

        // 스토어 앱이 없는 사람에게는 이것이 유일한 입구다 (이슈 #17). 목록에서
        // 뺐다고 받을 길까지 없애면 아무도 시작할 수 없다.
        var bootstrap: StoreAppBootstrapRow?
        if let storeAppID,
           let storeApp = settled.first(where: { (try? $0.requireID()) == storeAppID }),
           let released = latest[storeAppID],
           let versionID = released.id
        {
            bootstrap = StoreAppBootstrapRow(
                name: storeApp.name,
                version: "\(released.shortVersion) (빌드 \(released.buildNumber))",
                downloadPath:
                    "/apps/\(storeAppID.uuidString)/versions/\(versionID.uuidString)/download"
            )
        }

        // **감추기만 하면 워커가 실패했을 때 찾을 방법이 없다.** 목록에서 빼되 올린
        // 사람에게는 몇 개가 걸려 있는지와 가는 길을 남긴다. 남의 것은 보이지 않는다.
        let userID = try user.requireID()
        let mine = try unsettled.filter { app in
            user.role.canAdminister || app.$owner.id == userID
        }.map { app in
            PendingAppRow(id: try app.requireID().uuidString, name: app.name)
        }

        return try await request.view.render(
            "apps",
            AppListContext(
                page: try await request.pageContext(title: "앱"),
                apps: rows,
                canRegister: user.role.canPublish,
                pendingApps: mine,
                storeApp: bootstrap
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

    /// 이 사람에게 보이는 확인 중인 등록. 관리자는 전부 본다.
    private func pendingRows(for request: Request) async throws -> [PendingAppRow] {
        let user = try request.requireUser()
        let userID = try user.requireID()
        return try await App.query(on: request.db)
            .filter(\.$bundleIDPending == true)
            .all()
            .filter { user.role.canAdminister || $0.$owner.id == userID }
            .map { PendingAppRow(id: try $0.requireID().uuidString, name: $0.name) }
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
                enforceBundleIDPrefix: settings.enforceBundleIDPrefix,
                appsPath: APIPath.apps,
                versionRootPath: "\(APIPath.apiRoot)/versions",
                pendingApps: try await pendingRows(for: request)
            )
        ).get()
    }

    // MARK: - 상세

    /// 앱 상세.
    ///
    /// **스토어 앱은 여기로 오지 않는다.** 그 앱에 관한 일은 관리 > 스토어 앱 한
    /// 화면에서 끝난다 (ADR-0046). 화면이 둘이면 출시를 어디서 하는지가 갈리고,
    /// 목록에서 빼놓고 상세만 남겨두면 들어갈 수 없는 자리가 된다.
    @Sendable
    func detail(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()

        if try await request.storeAppSettings().$app.id == app.requireID() {
            return request.redirect(
                to: user.role.canAdminister ? AdminTab.storeApp.path : "/apps"
            )
        }
        return htmlResponse(try await renderDetail(on: request, issuedToken: nil), status: .ok)
    }

    /// 상세 화면을 그린다.
    ///
    /// 방금 발급한 토큰이 있으면 함께 넘긴다. 서버는 해시만 갖고 있어서 다음 요청에는
    /// 보여줄 방법이 없다. 그래서 발급 직후에만 이 자리에 실린다.
    func renderDetail(
        on request: Request,
        issuedToken: IssuedDeployToken?,
        issuedFeed: IssuedFeedToken? = nil,
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
                        lastUsed: token.lastUsedAt.map { DateStyle.minute.display(from: $0) },
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

        // 이 앱이 스토어 앱인가. 스토어 앱만 웹에서 받을 수 있다 (이슈 #17).
        let isStoreApp = try await request.storeAppSettings().$app.id == app.requireID()
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
                        downloadCount: perVersion[try version.requireID()],
                        // 스토어 앱은 출시된 것만. 스토어 앱이 없는 사람에게 이것이
                        // 유일한 길이라 출시 전 것까지 열 이유가 없다.
                        isDownloadable: canUpload
                            || (isStoreApp && version.state.isPubliclyVisible)
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
                notificationError: notificationError,
                canUpload: canUpload,
                canManage: canManage,
                entitlementsWhereToFind: EntitlementsGuidance.whereToFind,
                entitlementsElectronTemplate: EntitlementsGuidance.electronTemplate,
                entitlementsElectronNotes: EntitlementsGuidance.electronTemplateNotes,
                removal: RemovalCostRow(try await AppRemoval.cost(of: app, on: request.db))
            )
        ).get()
    }

    /// 브라우저에서 바로 받는다 (이슈 #17).
    ///
    /// **스토어 앱의 부트스트랩을 위한 자리다.** 스토어 앱이 없는 사람에게는 스토어
    /// 앱을 받을 길이 이것뿐이다. 그 밖의 앱은 스토어 앱으로 받는다. 스토어 앱이 하는
    /// 검증 중 "이미 깔린 같은 앱과 서명한 팀이 같은가" 는 로컬을 알아야만 판단할 수
    /// 있어서 웹에서는 재현할 수 없고, 웹 다운로드가 기본 경로가 되면 그 판단을
    /// 건너뛰는 문이 된다.
    ///
    /// 이력은 API 경로와 같게 남긴다. 어디로 받았든 "누가 언제 무엇을 받았나" 는
    /// 같은 표에 있어야 한다.
    @Sendable
    func download(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        let version = try await request.findVersion()

        guard version.$app.id == (try app.requireID()) else {
            throw Abort(.notFound, reason: "이 앱의 버전이 아닙니다.")
        }

        let canUpload = try await app.canUpload(user, on: request.db)
        let isStoreApp = try await request.storeAppSettings().$app.id == app.requireID()

        // 화면에 링크를 그리는 조건과 같아야 한다. 화면이 안 그린다고 경로가 막히는
        // 것은 아니라서, 여는 조건은 여기가 기준이다.
        guard canUpload || (isStoreApp && version.state.isPubliclyVisible) else {
            throw Abort(
                .forbidden,
                reason: "이 앱은 스토어 앱에서 받습니다. 웹에서 바로 받을 수 있는 것은 스토어 앱 자신뿐입니다."
            )
        }
        guard let artifact = version.bestArtifact else {
            throw Abort(.conflict, reason: "이 버전에는 내려받을 파일이 없습니다.")
        }

        // URL 을 내주기 전에 남긴다. 나중에 남기면 URL 만 받고 이력이 빠지는 경로가 생긴다.
        try await Download(
            userID: try user.requireID(),
            versionID: try version.requireID()
        ).save(on: request.db)

        let presigned = try await request.artifactStorage.downloadURL(key: artifact.storageKey)
        request.logger.notice(
            "웹에서 내려받습니다 [\(app.bundleID) \(version.shortVersion) (\(version.buildNumber)), 받는 사람: \(user.email)]"
        )
        return request.redirect(to: presigned.url)
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

    // MARK: - 앱 치우기

    /// 앱을 지운다 (ADR-0041).
    @Sendable
    func deleteApp(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        let form = try? request.content.decode(DeleteAppForm.self)

        try await AppRemoval.remove(
            app,
            typedName: form?.confirmName,
            by: user,
            storage: request.application.artifactStorage,
            on: request.db,
            logger: request.logger
        )
        return request.redirect(to: "/apps")
    }

    // MARK: - 피드백

    // **남기는 경로는 여기 없다.** 피드백은 스토어 앱에서 받는다
    // (`POST /api/v1/versions/:id/feedback`). 앱을 실제로 받아 쓴 사람만 남길 수
    // 있어야 하는 값인데, 웹 콘솔에 오는 사람은 대개 올리는 쪽이다. 화면 하나에
    // 남기는 칸과 읽는 칸이 같이 있으면 그 구분이 흐려진다.
    //
    // 지우는 것은 남는다. 도를 넘은 글을 앱을 맡은 사람이 내릴 수 있어야 한다.

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
    /// 번들 ID 가 아직 정해지지 않았나. 이때만 지울 수 있다 (ADR-0039).
    var isPending: Bool
    /// 번들에서 뽑아둔 앱 아이콘. 안 올렸으면 nil 이고 목록이 `initial` 을 그린다.
    ///
    /// 스토어 앱 목록에는 아이콘이 있는데 웹 목록에는 없었다. 같은 앱을 두 곳에서
    /// 보는데 한쪽만 얼굴이 있으면 같은 것으로 안 읽힌다.
    var iconURL: String?
    /// 아이콘이 없을 때 그 자리에 그릴 이름 첫 글자.
    ///
    /// CSS 로 자르지 않는다. 한글은 한 글자가 두 칸 너비라 `width: 1ch` 로 자르면
    /// 글자가 세로로 반 잘린다. 실제로 "가드" 가 "가|" 로 나왔다. 어디서 끊어야
    /// 하는지는 문자를 아는 쪽만 안다.
    var initial: String

    init(app: App, latestReleased: Version?, rating: RatingSummary? = nil) throws {
        self.id = try app.requireID().uuidString
        // 확정 전에는 임시값 대신 상태를 보여준다. `alley-pending.<uuid>` 는 우리가
        // 자리를 채우려고 넣은 값이지 이 앱의 정체성이 아니다 (ADR-0034).
        self.bundleID = app.bundleIDPending ? "확인 중" : app.bundleID
        self.name = app.name
        self.summary = app.summary
        self.details = app.details
        self.category = app.category
        // 목록에서 오너를 함께 읽어두므로 여기서 관계를 만지지 않는다.
        self.ownerEmail = app.$owner.value?.email ?? ""
        self.latestReleasedVersion = latestReleased?.shortVersion
        self.ratingAverage = rating?.displayAverage
        self.ratingCount = rating?.count ?? 0
        self.isPending = app.bundleIDPending
        self.iconURL = app.iconURL
        self.initial = app.name.first.map(String.init) ?? "?"
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
    var createdAt: DisplayDate
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
    /// 권한이 모자라 실패했나. 그때만 재시도 자리에 entitlements 칸을 낸다 (ADR-0036).
    var needsEntitlements: Bool
    /// 이 버전을 받아간 횟수. 셀 수 없으면 nil.
    var downloadCount: Int?
    /// 무엇으로 서명했는지. 업로더가 준 entitlements 의 키를 한 줄씩 늘어놓는다.
    ///
    /// 비밀이 아니다. 앱이 실행되자마자 죽을 때 "권한이 붙긴 했나"를 화면에서 바로
    /// 확인할 수 있어야 한다. 안 올렸으면 nil 이고 화면에 아무것도 나오지 않는다.
    var entitlementKeys: String?
    /// 브라우저에서 바로 받을 수 있는 자리. 없으면 링크를 그리지 않는다.
    ///
    /// **모든 앱에 주지 않는다** (이슈 #17). 스토어 앱은 검증하고 설치하는 코드를
    /// 갖고 있는데 (`BundleVerifier`), 그중 "이미 깔린 같은 앱과 서명한 팀이 같은가"
    /// 는 로컬에 무엇이 깔렸는지 알아야만 판단할 수 있어서 웹에서는 불가능하다.
    /// 웹 다운로드를 기본 경로로 두면 그 판단을 건너뛰는 문이 된다.
    ///
    /// 그래서 두 경우만 연다. 스토어 앱 자신(그것이 없으면 아무것도 받을 수 없다)과,
    /// 올릴 권한이 있는 사람(어차피 올린 파일을 갖고 있고 서명 결과를 확인할 이유가
    /// 있다)이다.
    var downloadPath: String?

    init(
        version: Version,
        report: SigningJob.Report? = nil,
        downloadCount: Int? = nil,
        isDownloadable: Bool = false
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
        self.createdAt = DateStyle.day.display(from: version.createdAt ?? Date())
        self.failureReason = version.failureReason
        self.log = report?.log
        // 코드를 그대로 내보내지 않는다. 사람이 읽는 문장과 함께만 보여준다 (ADR-0023).
        self.failureTitle = report?.failureCode.map(SigningFailureGuidance.title)
        self.failureAdvice = report?.failureCode.map(SigningFailureGuidance.whatToDo)
        self.failureCode = report?.failureCode?.rawValue
        self.canRetry = version.state == .failed
        self.needsEntitlements = version.state == .failed
            && report?.failureCode == .entitlementsRejected
        self.downloadCount = downloadCount

        let keys = version.entitlements.map(EntitlementsPlist.keys(of:)) ?? []
        self.entitlementKeys = keys.isEmpty ? nil : keys.joined(separator: "\n")

        // 받을 파일이 실제로 있어야 한다. 눌러도 "파일이 없습니다" 가 나오는 링크는
        // 없는 것만 못하다.
        let hasArtifact = version.bestArtifact != nil
        self.downloadPath = isDownloadable && hasArtifact
            ? "/apps/\(version.$app.id.uuidString)/versions/\(self.id)/download"
            : nil
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

/// 등록이 끝나지 않은 앱 한 줄. 올린 사람에게만 보인다.
struct PendingAppRow: Encodable {
    var id: String
    var name: String
}

struct AppListContext: Encodable {
    var page: PageContext
    var apps: [AppRow]
    var canRegister: Bool
    var pendingApps: [PendingAppRow] = []
    /// 스토어 앱을 받는 자리. 출시본이 없으면 nil 이다.
    var storeApp: StoreAppBootstrapRow?
}

/// 목록 맨 위에 두는 스토어 앱 안내.
struct StoreAppBootstrapRow: Encodable {
    var name: String
    var version: String
    var downloadPath: String
}

struct AppFormContext: Encodable {
    var page: PageContext
    var values: AppFormValues
    var error: String?
    var bundleIDPrefix: String?
    var enforceBundleIDPrefix: Bool
    /// 등록과 첫 버전 업로드를 한 화면에서 하려면 이 둘이 필요하다.
    /// 스크립트가 없으면 폼이 그대로 `POST` 되어 등록만 된다 (ADR-0031).
    var appsPath: String
    var versionRootPath: String
    /// 이 사람이 걸어둔 확인 중인 등록. 같은 앱을 또 만들지 않게 보여준다 (ADR-0039).
    var pendingApps: [PendingAppRow]
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
    /// 익명 체크박스를 띄울지. 스토어 설정에서 온다.
    var notificationError: String?
    var canUpload: Bool
    var canManage: Bool
    /// 권한이 모자라 실패한 버전 옆에 붙일 안내. 그 파일을 어디서 구하나 (ADR-0036).
    var entitlementsWhereToFind: String
    /// 그 파일이 아예 없는 사람을 위한 본보기. Electron 앱 기준이다.
    var entitlementsElectronTemplate: String
    /// 본보기를 그대로 쓰기 전에 알아야 할 것.
    var entitlementsElectronNotes: String
    /// 지우면 무엇이 사라지는지 (ADR-0041).
    var removal: RemovalCostRow
}

/// 지우기 전에 보여줄 것. 숫자를 안 보여주면 무엇을 잃는지 모르고 누른다.
struct RemovalCostRow: Encodable {
    var versions: Int
    var downloads: Int
    /// 이름을 적어야 지워지는가. 한 번이라도 나갔거나 받아간 기록이 있으면 그렇다.
    var needsTypedName: Bool

    init(_ cost: AppRemoval.Cost) {
        self.versions = cost.versions
        self.downloads = cost.downloads
        self.needsTypedName = cost.needsTypedName
    }
}

/// 지우기 폼이 보내는 것. 잃을 것이 있는 앱에서만 이름을 받는다 (ADR-0041).
struct DeleteAppForm: Content {
    var confirmName: String?
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
    var createdAt: DisplayDate
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
    var lastUsed: DisplayDate?
    var isActive: Bool

    init(id: String, name: String, lastUsed: DisplayDate?, isActive: Bool) {
        self.id = id
        self.name = name
        self.lastUsed = lastUsed
        self.isActive = isActive
    }

    init(token: DeployToken) throws {
        self.init(
            id: token.id?.uuidString ?? "",
            name: token.name,
            lastUsed: token.lastUsedAt.map { DateStyle.minute.display(from: $0) },
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

/// 화면에 넘기는 날짜.
///
/// **표시 문자열과 ISO 8601 을 함께 담는다.** 서버가 만든 문자열은 서버 타임존
/// 기준인데, 컨테이너는 보통 UTC 라 보는 사람의 시각과 어긋난다. 그렇다고 서버에
/// 타임존을 박으면 다른 시간대에서 보는 사람이 또 어긋난다.
///
/// 그래서 ISO 를 함께 보내고 브라우저가 자기 타임존으로 다시 그린다. 스크립트가
/// 돌지 않아도 `display` 가 그대로 보이므로 화면이 비지는 않는다.
struct DisplayDate: Encodable {
    /// 서버가 만든 값. 스크립트가 없을 때 그대로 보인다.
    let display: String
    /// `<time datetime>` 에 넣는 값. 브라우저가 이것으로 로컬 시각을 만든다.
    let iso: String
    /// 날짜만 쓰는 자리인지. 브라우저가 시각을 붙일지 정하는 데 쓴다.
    let dateOnly: Bool
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

    /// 화면용. 알림 문구처럼 브라우저를 거치지 않는 곳은 `string(from:)` 을 쓴다.
    ///
    /// 포매터를 `static let` 으로 두지 않는다. `ISO8601DateFormatter` 가 Sendable 이
    /// 아니라 Swift 6 에서 막힌다. 위 `string(from:)` 도 같은 이유로 매번 만든다.
    func display(from date: Date) -> DisplayDate {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return DisplayDate(
            display: string(from: date),
            iso: formatter.string(from: date),
            dateOnly: self == .day
        )
    }
}
