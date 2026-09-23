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
        pages.post(":appID", "portal-app-id", use: registerPortalAppID)
        pages.post(":appID", "deploy-tokens", use: issueDeployToken)
        pages.post(":appID", "deploy-tokens", ":tokenID", "revoke", use: revokeDeployToken)
        pages.get(":appID", "member-candidates", use: memberCandidates)
        pages.post(":appID", "members", use: addMember)
        pages.post(":appID", "members", ":userID", "remove", use: removeMember)
        pages.post(":appID", "owner", use: submitOwner)
        pages.get(":appID", "versions", ":versionID", "download", use: download)
        pages.post(":appID", "feedback", ":feedbackID", "delete", use: deleteFeedback)
        pages.post(":appID", "feed-tokens", use: issueFeedToken)
        pages.post(":appID", "feed-tokens", ":tokenID", "revoke", use: revokeFeedToken)
        pages.post(":appID", "alerts", use: submitAlerts)
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
            // **손댈 수 있는 앱만 보인다** (ADR-0051). 여기는 앱을 올리는 사람의
            // 화면이라 남의 앱은 등록·업로드·토큰·통계 어느 것도 할 수 없으면서 줄만
            // 차지한다. 받을 수도 없다 (이슈 #17). 카탈로그는 스토어 앱이 그린다.
            guard try visibility.canTouch(app) else { return nil }
            return try AppRow(app: app, latestReleased: latest[appID], rating: ratings[appID])
        }

        // 스토어 앱이 없는 사람에게는 이것이 유일한 입구다 (이슈 #17). 목록에서
        // 뺐다고 받을 길까지 없애면 아무도 시작할 수 없다.
        var bootstrap: StoreAppBootstrapRow?
        if let storeAppID,
           let storeApp = settled.first(where: { (try? $0.requireID()) == storeAppID }),
           let released = latest[storeAppID],
           let versionID = released.id
        {
            _ = versionID
            bootstrap = StoreAppBootstrapRow(
                name: storeApp.name,
                version: "\(released.shortVersion) (빌드 \(released.buildNumber))",
                // **받는 자리는 `/get` 하나다** (ADR-0049, ADR-0050). 여기서 버전
                // 경로를 따로 가리키면 그쪽은 `bestArtifact` 를 주는데, 그것은 zip 이다.
                // 같은 줄에서 "받으세요" 를 눌렀는데 공개 페이지와 다른 파일이 나온다.
                //
                // `bestArtifact` 를 dmg 로 바꿀 수는 없다. 스토어 앱 클라이언트가
                // 자기 업데이트를 그 값으로 받고, 받은 것을 푸는 코드라 dmg 를 주면
                // 깨진다 (`Installer`).
                path: "/" + StoreAppGetController.path
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
        feedError: String? = nil,
        portalError: String? = nil,
        portalNotice: String? = nil,
        memberError: String? = nil
    ) async throws -> View {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.$owner.load(on: request.db)

        let canUpload = try await app.canUpload(user, on: request.db)
        let canManage = try app.canManage(user)
        let versions = try await app.visibleVersions(for: user, on: request.db)

        // **상세는 목록보다 넓다** (ADR-0051). 목록은 "내가 맡은 것" 이라 남의 앱을
        // 빼지만, 상세는 주소를 알고 찾아온 자리다. 출시된 앱이면 보여준다. 별점과
        // 피드백을 읽는 길이고, 손대는 것은 어차피 따로 막혀 있다(`canManage`).
        //
        // 출시본이 하나도 없는 앱은 받을 사람에게 보일 이유가 없다.
        guard canUpload || versions.contains(where: { $0.state.isPubliclyVisible }) else {
            throw Abort(.notFound, reason: "앱을 찾을 수 없습니다.")
        }

        var members: [AppMemberDTO] = []
        if canUpload {
            members = try await loadMembers(of: app, on: request.db)
        }

        // 멤버로 넣을 사람 찾기. 관리하는 사람에게만 연다.
        //
        // **한 번이라도 로그인한 사람 중에서만 고른다.** 계정이 없는 이메일을 미리
        // 넣어두면 오타를 알아챌 방법이 없다. API 가 이미 같은 규칙으로 거절한다.
        var memberCandidates: [MemberCandidateRow] = []
        let memberQuery = request.query[String.self, at: "member"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var memberSearchOverflowed = false
        if canManage, let memberQuery, !memberQuery.isEmpty {
            let found = try await PersonSearch.find(
                matching: memberQuery,
                excluding: Set(members.map(\.user.id)),
                on: request.db
            )
            memberSearchOverflowed = found.overflowed
            memberCandidates = found.candidates
        }

        // 피드 주소를 내주는 화면과 같은 조건이다. 거기서만 쓴다.
        var sparkle: SparkleReadinessRow?
        if canManage {
            sparkle = try await SparkleReadinessRow.of(app: app, on: request.db)
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
                        issuedAt: DateStyle.minute.display(from: token.createdAt ?? Date()),
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

        // 보내는 방법. 관리 화면과 같은 부품을 쓴다 (ADR-0059).
        var alerts: AlertDeliveryContext?
        if canManage {
            let appID = try app.requireID()
            let channels = try await NotificationTarget.query(on: request.db)
                .filter(\.$app.$id == appID)
                .sort(\.$name)
                .all()
            let uploaderCount = members.count
            alerts = AlertDeliveryContext(
                target: app.alerts.rawValue,
                canReachPeople: request.application.canReachPeople,
                peopleName: "앱 관리자에 개별전송",
                // 뒤에 "개인이 내 알림에서 정할 수 있다" 가 템플릿에서 붙는다. 그
                // 문장에는 링크가 들어가는데 Leaf 는 넘긴 값을 이스케이프하므로
                // 여기에 태그를 적을 수 없다.
                peopleNote: "앱을 수정할 수 있는 권한이 있는 \(uploaderCount)명에게 개별로 보냅니다.",
                saveAction: "/apps/\(appID.uuidString)/alerts",
                channelAction: "/apps/\(appID.uuidString)/notification-targets",
                channels: AlertDeliveryContext.channels(channels) { id in
                    "/apps/\(appID.uuidString)/notification-targets/\(id.uuidString)/delete"
                },
                error: notificationError
            )
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

        // 프로필이 필요한 권한을 쓰는 앱만 포털에 App ID 가 있어야 한다 (ADR-0005).
        // 그 판단은 올린 entitlements 가 들어온 뒤에야 할 수 있어서, 앱을 만드는
        // 화면이 아니라 여기에 둔다.
        let profileEntitlements = canManage
            ? EntitlementsPlist.requiringProvisioningProfile(
                in: Set(versions.compactMap(\.entitlements).flatMap(EntitlementsPlist.keys(of:)))
            )
            : []
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
                ownerCandidates: members.filter { !$0.isOwner && $0.isActive != false },
                memberQuery: memberQuery,
                memberCandidates: memberCandidates,
                memberSearchOverflowed: memberSearchOverflowed,
                memberError: memberError,
                deployTokens: deployTokens,
                issuedToken: issuedToken,
                downloads: downloads,
                feedTokens: feedTokens,
                issuedFeed: issuedFeed,
                feedError: feedError,
                sparkle: sparkle,
                alerts: alerts,
                feedback: feedback,
                canUpload: canUpload,
                canManage: canManage,
                entitlementsWhereToFind: EntitlementsGuidance.whereToFind,
                entitlementsWhyItWorksLocally: EntitlementsGuidance.whyItWorksLocally,
                entitlementsElectronTemplate: EntitlementsGuidance.electronTemplate,
                entitlementsElectronNotes: EntitlementsGuidance.electronTemplateNotes,
                entitlementsElectronCaveat: EntitlementsGuidance.electronTemplateCaveat,
                profileEntitlements: profileEntitlements,
                // 연동이 없으면 눌러도 안 되는 버튼이라 아예 그리지 않는다.
                isPortalConfigured: request.application.alleyConfig.appStoreConnect != nil,
                portalError: portalError,
                portalNotice: portalNotice,
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

        // **스토어 앱을 받으러 온 사람은 공개 페이지로 보낸다** (ADR-0050). 여기서
        // 내주면 `bestArtifact` 라 zip 이 나가는데, 공개 페이지는 dmg 를 준다. 같은
        // 앱을 어디로 왔느냐에 따라 다른 파일로 받게 된다.
        //
        // 올릴 권한이 있는 사람은 그대로 둔다. 그 사람들은 특정 버전의 산출물을
        // 확인하려고 오는 것이지 앱을 설치하려고 오는 것이 아니다.
        if isStoreApp, !canUpload, version.state.isPubliclyVisible {
            return request.redirect(to: "/\(StoreAppGetController.path)/download")
        }

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

    // MARK: - 포털 App ID

    /// 이 앱의 번들 ID 로 Apple 포털에 explicit App ID 를 만든다 (ADR-0005).
    ///
    /// **값을 묻지 않는다.** 번들 ID 와 이름은 앱을 등록할 때 이미 받았다. 다시 적게
    /// 하면 오타가 그대로 Apple 계정에 남고, 거기서 지우는 것은 Account Holder 나
    /// Admin 만 할 수 있다.
    ///
    /// 앱 화면에 두는 이유는 판단 시점 때문이다. 프로필이 필요한지는 entitlements 를
    /// 봐야 아는데, 그것은 버전을 올릴 때 들어온다. 앱을 만드는 화면에는 아직 없다.
    @Sendable
    func registerPortalAppID(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        do {
            let registered = try await PortalRegistration.registerBundleID(
                RegisterBundleIDRequest(identifier: app.bundleID, name: app.name),
                using: try request.appStoreConnect(),
                by: user,
                logger: request.logger
            )
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                portalNotice: "'\(registered.identifier)' 를 Apple 계정에 만들었습니다."
            )
            return htmlResponse(view, status: .created)
        } catch let abort as any AbortError where abort.status.code < 500 {
            let view = try await renderDetail(
                on: request, issuedToken: nil, portalError: abort.reason
            )
            return htmlResponse(view, status: abort.status)
        }
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

    // MARK: - 업로드 권한

    /// 고른 사람에게 이 앱을 올릴 권한을 준다.
    ///
    /// 화면은 `AppController.addMember` 와 같은 규칙을 쓴다. 한 번이라도 로그인한
    /// 치는 동안 후보를 돌려준다.
    ///
    /// **화면을 다시 그리는 것과 같은 것을 본다.** 스크립트가 없으면 폼이 그대로
    /// 제출되고 서버가 같은 결과를 HTML 로 그린다. 그쪽이 사라지는 것이 아니라,
    /// 여기가 그 일을 한 조각만 떼어 빨리 하는 것이다.
    @Sendable
    func memberCandidates(request: Request) async throws -> MemberCandidatesResponse {
        let user = try request.requireUser()
        let app = try await request.findApp()
        // 누가 이 앱을 올릴 수 있는지는 관리하는 사람만 본다. 목록을 그리는 쪽과
        // 같은 조건이다.
        try app.requireManageAccess(for: user)

        let query = (request.query[String.self, at: "q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return MemberCandidatesResponse(candidates: [], overflowed: false)
        }

        let found = try await PersonSearch.find(
            matching: query,
            excluding: try await uploaderIDs(of: app, on: request.db),
            on: request.db
        )
        return MemberCandidatesResponse(
            candidates: found.candidates,
            overflowed: found.overflowed
        )
    }

    /// 계정만 넣을 수 있고, 오너는 이미 올릴 수 있으므로 표에 넣지 않는다.
    @Sendable
    func addMember(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(MemberFormValues.self)
        guard let id = values.userID.flatMap(UUID.init(uuidString:)),
              let target = try await User.find(id, on: request.db)
        else {
            // 검색 결과를 눌러서 오는 길이라 평소에는 일어나지 않는다. 고른 사이에
            // 계정이 사라졌거나 폼을 손으로 만든 경우다.
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                memberError: "고른 계정을 찾을 수 없습니다. 다시 검색해주세요."
            )
            return htmlResponse(view, status: .notFound)
        }
        // 검색에는 안 나오지만 폼을 손으로 만들거나 오래된 결과를 누르면 여기 온다.
        guard target.isActive else {
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                memberError: "끊은 계정에는 권한을 줄 수 없습니다."
            )
            return htmlResponse(view, status: .badRequest)
        }

        let appID = try app.requireID()
        let targetID = try target.requireID()
        if app.$owner.id != targetID {
            let existing = try await AppMember.query(on: request.db)
                .filter(\.$app.$id == appID)
                .filter(\.$user.$id == targetID)
                .first()
            if existing == nil {
                try await AppMember(appID: appID, userID: targetID).save(on: request.db)
                request.logger.notice(
                    "업로드 권한 추가 [앱: \(app.bundleID), 대상: \(target.email), 관리자: \(user.email)]"
                )
            }
        }
        return request.redirect(to: "/apps/\(appID.uuidString)#members")
    }

    /// 오너를 넘긴다 (ADR-0061).
    ///
    /// **올릴 수 있는 사람 중에서만 고른다.** 아무나 검색해 바로 주인을 바꾸게 하면
    /// 이 앱과 관계없는 사람이 한 번의 실수로 주인이 된다. 밖의 사람에게 넘길 때는
    /// 업로드 권한을 먼저 주면 후보에 들어온다.
    ///
    /// **지금 오너는 멤버로 남긴다.** 넘겼다고 올리지 못할 이유가 없고, 권한까지
    /// 잃으면 되돌릴 사람이 그 앱에서 사라진다.
    @Sendable
    func submitOwner(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(MemberFormValues.self)
        let appID = try app.requireID()
        let previousOwnerID = app.$owner.id

        guard let newOwnerID = values.userID.flatMap(UUID.init(uuidString:)),
              let newOwner = try await User.find(newOwnerID, on: request.db)
        else {
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                memberError: "넘길 사람을 찾을 수 없습니다. 다시 고르세요."
            )
            return htmlResponse(view, status: .notFound)
        }

        guard newOwnerID != previousOwnerID else {
            return request.redirect(to: "/apps/\(appID.uuidString)#members")
        }

        // 올릴 수 있는 사람만 받는다. 폼에는 그 사람들만 나오지만, 고르는 사이에
        // 권한이 회수됐거나 폼을 손으로 만들었을 수 있다.
        let isUploader = try await AppMember.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$user.$id == newOwnerID)
            .first() != nil
        guard isUploader else {
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                memberError: "올릴 수 있는 사람에게만 넘길 수 있습니다. 먼저 권한을 주세요."
            )
            return htmlResponse(view, status: .badRequest)
        }

        // 끊은 계정에 넘기면 그 앱은 그 자리에서 주인을 잃는다 (ADR-0061).
        guard newOwner.isActive else {
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                memberError: "끊은 계정에는 넘길 수 없습니다."
            )
            return htmlResponse(view, status: .badRequest)
        }

        app.$owner.id = newOwnerID
        try await app.save(on: request.db)

        // 새 오너의 멤버 행은 지운다. 오너는 언제나 올릴 수 있어서 표에 두지 않는
        // 것이 이 화면의 규칙이다.
        try await AppMember.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$user.$id == newOwnerID)
            .delete()

        let alreadyMember = try await AppMember.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$user.$id == previousOwnerID)
            .first() != nil
        if !alreadyMember {
            try await AppMember(appID: appID, userID: previousOwnerID).save(on: request.db)
        }

        request.logger.notice(
            "오너 변경 [앱: \(app.bundleID), 새 오너: \(newOwner.email), 바꾼 사람: \(user.email)]"
        )
        return request.redirect(to: "/apps/\(appID.uuidString)#members")
    }

    /// 업로드 권한을 거둔다. 오너는 표에 없으므로 여기로 오지 않는다.
    @Sendable
    func removeMember(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        guard let raw = request.parameters.get("userID"),
              let targetID = UUID(uuidString: raw)
        else {
            throw Abort(.badRequest, reason: "사용자를 알 수 없습니다.")
        }

        let appID = try app.requireID()
        try await AppMember.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$user.$id == targetID)
            .delete()
        request.logger.notice(
            "업로드 권한 제거 [앱: \(app.bundleID), 대상: \(targetID), 관리자: \(user.email)]"
        )
        return request.redirect(to: "/apps/\(appID.uuidString)#members")
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
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#deploy-tokens")
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

    /// 이 앱이 정한 곳으로 새 피드백을 알린다 (ADR-0059).
    ///
    /// 채널이냐 개별이냐는 앱 설정이 정하고, 개별이면 받는 사람이 각자 끌 수 있다.
    /// 예전에는 채널로 보내면서 따로 켠 사람에게 한 통을 더 보냈는데, 그 "한 통 더"
    /// 를 켠 사람이 없어서 채널을 안 걸어둔 앱은 아무 데도 가지 않았다.
    private func announce(
        _ entry: Feedback,
        version: Version,
        by user: User,
        on request: Request
    ) async {
        let stars = entry.rating.map { String(repeating: "★", count: $0) } ?? ""
        let who = entry.isAnonymous ? "익명" : user.name
        let message = NotificationMessage(
            title: "\(version.app.name) \(version.shortVersion) (\(version.buildNumber)) 에 새 피드백",
            body: [stars, entry.body, "— \(who)"]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            link: request.consoleLink("/apps/\(version.$app.id.uuidString)")
        )

        await request.notifier.notify(app: version.app, kind: .feedback, message: message)
    }

    // MARK: - 피드 토큰

    @Sendable
    func issueFeedToken(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        // **화면만 가리면 막은 것이 아니다.** 여기까지 오는 길은 폼을 손으로 만드는
        // 것뿐이지만, 내주고 나면 주소가 나오고 주소가 나오면 된 줄 안다 (ADR-0057).
        let sparkle = try await SparkleReadinessRow.of(app: app, on: request.db)
        guard sparkle.canIssue else {
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                feedError: sparkle.blocker ?? "지금은 피드 주소를 내줄 수 없습니다."
            )
            return htmlResponse(view, status: .conflict)
        }

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
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#feed-tokens")
    }

    // MARK: - 알림 대상

    @Sendable
    func addNotificationTarget(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(NotificationTargetFormValues.self)
        // **채널만 등록한다** (ADR-0059). 사람에게 보내는 길은 개별 전송이 맡고,
        // 그쪽은 받는 사람이 각자 수단을 정하므로 여기서 주소를 받을 것이 없다.
        do {
            _ = try await NotificationTargets.create(
                CreateNotificationTargetRequest(
                    kind: .slack,
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
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#alerts")
    }

    /// 이 앱의 소식을 채널로 보낼지 개별로 보낼지 (ADR-0059).
    @Sendable
    func submitAlerts(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let values = try request.content.decode(OperationalTargetValues.self)
        guard let target = AlertDelivery(rawValue: values.target ?? "") else {
            throw Abort(.badRequest, reason: "알 수 없는 값입니다: \(values.target ?? "")")
        }
        // 받아 봐야 아무 데도 가지 않는 설정이 저장되고, 고른 사람은 받고 있다고
        // 믿는다. 오류 화면으로 보내지 않고 이 화면에 이유만 띄운다.
        if target == .people, !request.application.canReachPeople {
            let view = try await renderDetail(
                on: request,
                issuedToken: nil,
                notificationError: "Slack 봇도 메일도 연결되어 있지 않아 개별 전송을 고를 수 없습니다."
            )
            return htmlResponse(view, status: .conflict)
        }

        app.alerts = target
        try await app.save(on: request.db)
        request.logger.notice(
            "앱 알림 대상 변경 [\(app.bundleID), \(target.rawValue), 바꾼 사람: \(user.email)]"
        )
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#alerts")
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
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#alerts")
    }


    /// 이 앱에 이미 올릴 수 있는 사람들의 id.
    ///
    /// **`loadMembers` 를 쓰지 않는다.** 그쪽은 오너를 미리 읽어둔 앱을 전제한다
    /// (`app.owner`). 화면을 그리는 길은 그렇게 읽지만 다른 길은 아니라서, 거기서
    /// 부르면 관계를 안 읽었다고 죽는다. 여기는 id 만 있으면 된다.
    private func uploaderIDs(of app: App, on database: any Database) async throws -> Set<UUID> {
        let members = try await AppMember.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .all()
            .map(\.$user.id)
        return Set(members + [app.$owner.id])
    }

    private func loadMembers(of app: App, on database: any Database) async throws -> [AppMemberDTO] {
        let ownerID = app.$owner.id
        let members = try await AppMember.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .with(\.$user)
            .all()

        return try [AppMemberDTO(user: app.owner.toDTO(), isOwner: true, isActive: app.owner.isActive)]
            + members
            .filter { $0.$user.id != ownerID }
            .map { AppMemberDTO(user: try $0.user.toDTO(), isOwner: false, isActive: $0.user.isActive) }
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
    /// 이 줄에 실패 이야기를 펼칠 것이 있나.
    ///
    /// 화면이 `failureTitle` 과 `failureReason` 을 각각 물어 두 번 갈라지지 않게 한다.
    /// 갈래를 모르는 옛 잡은 제목 없이 원문만 있어서, 한쪽만 보면 그 줄을 놓친다.
    var hasFailure: Bool
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
        self.hasFailure = self.failureTitle != nil || self.failureReason != nil
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
    /// 받는 자리. 공개 페이지 하나로 모은다 (ADR-0049).
    var path: String
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
    /// 오너로 넘길 수 있는 사람들. 오너 자신과 끊긴 계정을 뺀 멤버들이다.
    ///
    /// 화면에서 거르지 않고 여기서 거른다. 비어 있으면 폼 자체를 내지 않아야 하는데,
    /// 템플릿에서는 거른 뒤의 수를 셀 수 없다.
    var ownerCandidates: [AppMemberDTO]
    /// 방금 친 검색어. 다시 그릴 때 칸에 그대로 남긴다.
    var memberQuery: String?
    /// 그 검색어로 찾은 사람들. 이미 올릴 수 있는 사람은 빠져 있다.
    var memberCandidates: [MemberCandidateRow]
    /// 후보가 화면에 세울 수보다 많았나. 그러면 더 좁혀 치라고 알린다.
    var memberSearchOverflowed: Bool
    var memberError: String?
    var deployTokens: [DeployTokenRow]
    var issuedToken: IssuedDeployToken?
    /// 다운로드 요약. 올릴 권한이 없는 사람에게는 nil.
    var downloads: DownloadSummaryRow?
    var feedTokens: [DeployTokenRow]
    var issuedFeed: IssuedFeedToken?
    var feedError: String?
    /// Sparkle 을 실제로 쓸 수 있는 상태인가 (ADR-0057). 관리 권한이 없으면 nil.
    var sparkle: SparkleReadinessRow?
    /// 보내는 방법. 관리 권한이 없으면 nil (ADR-0059).
    var alerts: AlertDeliveryContext?
    var feedback: [FeedbackRow]
    /// 지금 사람이 피드백을 남길 수 있는 버전들. 받아본 것만 들어온다.
    /// 익명 체크박스를 띄울지. 스토어 설정에서 온다.
    var canUpload: Bool
    var canManage: Bool
    /// 권한이 모자라 실패한 버전 옆에 붙일 안내. 그 파일을 어디서 구하나 (ADR-0036).
    var entitlementsWhereToFind: String
    /// 왜 내 맥에서는 되는데 여기서는 안 되나. 멀쩡히 쓰던 앱이라 이 줄이 없으면
    /// 실패가 오진처럼 읽힌다.
    var entitlementsWhyItWorksLocally: String
    /// 그 파일이 아예 없는 사람을 위한 본보기. Electron 앱 기준이다.
    var entitlementsElectronTemplate: String
    /// 본보기 앞에 세우는 한 줄. 이것이 무엇이고 무엇을 하면 되는지.
    var entitlementsElectronNotes: String
    /// 본보기 뒤에 붙는 한 줄. 그대로 쓰면 안 되는 경우.
    var entitlementsElectronCaveat: String
    /// 이 앱이 쓰는 권한 중 프로비저닝 프로필을 요구하는 것들 (ADR-0005).
    ///
    /// 비어 있으면 포털에 App ID 를 만들 이유가 없고, 그 자리를 그리지 않는다.
    /// 관리할 수 없는 사람에게는 늘 비어 있다.
    var profileEntitlements: [String]
    /// App Store Connect 연동이 서 있는가.
    var isPortalConfigured: Bool
    /// App ID 를 만들다 막힌 이유.
    var portalError: String?
    /// 만들었거나 이미 있었다는 알림.
    var portalNotice: String?
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

/// 검색 결과 한 줄.
struct MemberCandidateRow: Encodable {
    var id: String
    var email: String
    var name: String
}

/// 치는 동안 돌려주는 후보들.
///
/// 내보내기만 한다. 받을 일이 없어서 `Decodable` 은 달지 않는다.
struct MemberCandidatesResponse: Encodable, AsyncResponseEncodable {
    var candidates: [MemberCandidateRow]
    /// 화면에 세울 수보다 많았나. 그러면 더 좁혀 치라고 알린다.
    var overflowed: Bool

    func encodeResponse(for request: Request) async throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(self, as: .json)
        return response
    }
}

struct MemberFormValues: Codable {
    /// 검색 결과에서 고른 사람. 이메일이 아니라 id 로 받는다.
    ///
    /// 이메일로 받으면 고른 뒤 그 사람이 이메일을 바꿨을 때 엉뚱한 계정에 붙거나
    /// 못 찾는다. 화면이 이미 계정을 특정해 놓은 상태라 id 를 그대로 넘긴다.
    var userID: String?
}

extension MemberFormValues: Content {}

struct DeployTokenRow: Encodable {
    var id: String
    var name: String
    /// 언제 발급한 것인지. 폐기하고 같은 이름으로 다시 발급하면 이름과 상태만으로는
    /// 두 줄을 구별할 수 없다. 둘 다 쓴 적이 없으면 더욱 그렇다.
    var issuedAt: DisplayDate
    var lastUsed: DisplayDate?
    var isActive: Bool

    init(id: String, name: String, issuedAt: DisplayDate, lastUsed: DisplayDate?, isActive: Bool) {
        self.id = id
        self.name = name
        self.issuedAt = issuedAt
        self.lastUsed = lastUsed
        self.isActive = isActive
    }

    init(token: DeployToken) throws {
        self.init(
            id: token.id?.uuidString ?? "",
            name: token.name,
            issuedAt: DateStyle.minute.display(from: token.createdAt ?? Date()),
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
