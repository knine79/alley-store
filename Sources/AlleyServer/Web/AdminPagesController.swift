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

        // 이미지만 본문이 크다. 이 경로에만 따로 상한을 준다 (ADR-0016 과 같은 이유).
        pages.on(
            .POST,
            "settings", "branding", ":kind",
            body: .collect(maxSize: .init(value: BrandingAssetService.maximumUploadSize)),
            use: submitBrandingAsset
        )
        pages.post("settings", "branding", ":kind", "remove", use: removeBrandingAsset)
        pages.get("users", use: userList)
        pages.post("users", ":userID", "role", use: submitRole)
        pages.get("workers", use: workerList)
        pages.post("workers", use: registerWorker)
        pages.post("workers", ":workerID", "revoke", use: revokeWorker)
        pages.post("workers", "releases", use: uploadWorkerRelease)
        pages.post("workers", "releases", ":releaseID", "deploy", use: deployWorkerRelease)
        pages.post("workers", "releases", ":releaseID", "delete", use: deleteWorkerRelease)
        pages.post("operator-tokens", use: issueOperatorToken)
        pages.post("operator-tokens", ":tokenID", "revoke", use: revokeOperatorToken)
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
            // 이미지 업로드는 화면을 다시 그리지 않고 이유를 실어 돌려보낸다
            // (`back(to:error:on:)` 참고).
            error: request.query[String.self, at: "error"],
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
                page: try await request.pageContext(adminTab: .settings),
                values: values,
                branding: BrandingSlot.rows(
                    for: [.favicon, .logo],
                    assets: try await BrandingAssetService.all(on: request.db)
                ),
                error: error,
                saved: saved
            )
        ).get()
    }

    // MARK: - 브랜딩 이미지

    /// 파비콘·로고를 올린다. 앱 아이콘은 스토어 앱 화면에서 같은 경로로 올린다.
    @Sendable
    func submitBrandingAsset(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let kind = try Self.requireBrandingKind(on: request)
        let form = try request.content.decode(BrandingUploadForm.self)

        guard let file = form.image, file.data.readableBytes > 0 else {
            return Self.back(to: form.returnPath, error: "올릴 \(kind.label) 파일을 고르세요.", on: request)
        }
        do {
            try await BrandingAssetService.accept(
                kind: kind,
                data: Data(buffer: file.data),
                by: admin,
                storage: request.application.artifactStorage,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError {
            return Self.back(to: form.returnPath, error: abort.reason, on: request)
        }
        return Self.back(to: form.returnPath, error: nil, on: request)
    }

    @Sendable
    func removeBrandingAsset(request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let kind = try Self.requireBrandingKind(on: request)
        let form = try? request.content.decode(BrandingUploadForm.self)

        try await BrandingAssetService.remove(
            kind: kind,
            storage: request.application.artifactStorage,
            on: request.db,
            logger: request.logger
        )
        return Self.back(to: form?.returnPath, error: nil, on: request)
    }

    private static func requireBrandingKind(on request: Request) throws -> BrandingAssetKind {
        guard let raw = request.parameters.get("kind"),
              let kind = BrandingAssetKind(rawValue: raw)
        else {
            throw Abort(.notFound, reason: "알 수 없는 브랜딩 이미지 종류입니다.")
        }
        return kind
    }

    /// 이미지를 올린 화면으로 돌려보낸다.
    ///
    /// 다른 폼처럼 화면을 다시 그리지 않는 이유는 **되살릴 값이 없어서**다. 사용자가
    /// 고른 것은 파일 하나이고 브라우저는 그것을 돌려주지 않는다. 다시 그려도 빈 칸이
    /// 나오므로, 돌아갈 자리에 이유만 실어 보낸다.
    ///
    /// 같은 폼이 스토어 설정과 스토어 앱 두 화면에 있어서 돌아갈 자리를 폼이 들고
    /// 온다. 값이 없으면 스토어 설정으로 간다.
    private static func back(to path: String?, error: String?, on request: Request) -> Response {
        // 열린 리다이렉트를 만들지 않는다. 폼에 실려오는 값이라 손댈 수 있고,
        // `//evil.example` 은 브라우저가 다른 호스트로 읽는다.
        let target = (path?.hasPrefix("/") == true && path?.hasPrefix("//") == false)
            ? path! : AdminTab.settings.path

        var components = URLComponents(string: target) ?? URLComponents()
        components.queryItems = [
            error.map { URLQueryItem(name: "error", value: $0) } ?? URLQueryItem(name: "saved", value: "1")
        ]
        return request.redirect(to: components.string ?? AdminTab.settings.path)
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
                page: try await request.pageContext(adminTab: .users),
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
        issuedOperatorToken: String? = nil,
        on request: Request
    ) async throws -> View {
        // 폐기한 워커도 함께 읽어 화면에서 나눈다. 행은 지우지 않는다. 잡 이력이
        // 이 워커를 가리키고, "이 토큰이 존재했다" 는 것 자체가 기록이다. 다만 맥을
        // 교체할 때마다 목록이 한 줄씩 길어지므로, 기본 목록은 현역만 보여주고
        // 폐기된 것은 접어둔다.
        let workerRows = try await Worker.query(on: request.db)
            .sort(\.$name)
            .all()
            .map { try WorkerRow(worker: $0) }
        let operatorTokenRows = try await OperatorToken.query(on: request.db)
            .sort(\.$createdAt, .descending)
            .all()
            .map { try OperatorTokenRow(token: $0) }
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
                page: try await request.pageContext(adminTab: .workers),
                workers: workerRows.filter(\.isActive),
                revokedWorkers: workerRows.filter { !$0.isActive },
                jobs: jobs.map { SigningJobRow(job: $0) },
                issued: issued.map { IssuedWorkerToken(name: $0.worker.name, token: $0.token) },
                error: error,
                serverWorkerVersion: WorkerVersion.current,
                releases: try await WorkerRelease.query(on: request.db)
                    .sort(\.$createdAt, .descending)
                    .all()
                    .map { try WorkerReleaseRow(release: $0) },
                operatorTokens: operatorTokenRows.filter(\.isActive),
                revokedOperatorTokens: operatorTokenRows.filter { !$0.isActive },
                issuedOperatorToken: issuedOperatorToken.map { IssuedOperatorToken(value: $0) }
            )
        ).get()
    }

    // MARK: - 운영 토큰

    /// 운영 파이프라인이 쓸 토큰을 발급한다 (ADR-0043).
    ///
    /// 발급 직후 한 번만 보여준다. 서버는 해시만 들고 있다.
    @Sendable
    func issueOperatorToken(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let form = try request.content.decode(OperatorTokenForm.self)
        let name = (form.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return try await redirectWithError("토큰 이름을 적으세요.", on: request)
        }

        // 쓸 수 있는 토큰끼리는 이름이 겹치지 않게 한다. 목록에 나오는 것은 이름과
        // 시각뿐이라, 이름이 같으면 어느 쪽이 파이프라인에 들어 있는 토큰인지 화면에서
        // 가릴 수 없다. 실제로 이름이 같은 토큰이 셋 쌓인 적이 있고, 그때 폐기한 토큰이
        // 다시 나타난 것으로 보였다.
        //
        // 발급 화면은 리다이렉트하지 않으므로(아래 주석 참고) 새로고침하면 브라우저가
        // 같은 폼을 다시 보낸다. 그 재제출도 여기서 걸린다.
        let sameName = try await OperatorToken.query(on: request.db)
            .filter(\.$name == name)
            .all()
        guard !sameName.contains(where: \.isActive) else {
            return try await redirectWithError(
                "'\(name)' 은 이미 쓸 수 있는 운영 토큰입니다. 새로 발급하려면 그것부터 폐기하세요.",
                status: .conflict,
                on: request
            )
        }

        let value = OperatorToken.generateToken()
        let token = OperatorToken(
            name: name,
            tokenHash: OperatorToken.hash(token: value),
            createdByID: try admin.requireID()
        )
        try await token.save(on: request.db)
        request.logger.notice("운영 토큰 발급 [이름: \(name), 관리자: \(admin.email)]")

        let view = try await renderWorkers(
            issued: nil, error: nil, issuedOperatorToken: value, on: request
        )
        let response = Response(status: .ok)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
    }

    @Sendable
    func revokeOperatorToken(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        guard let id = request.parameters.get("tokenID", as: UUID.self),
              let token = try await OperatorToken.find(id, on: request.db)
        else {
            throw Abort(.notFound, reason: "토큰을 찾을 수 없습니다.")
        }
        token.revokedAt = Date()
        try await token.save(on: request.db)
        request.logger.notice("운영 토큰 폐기 [이름: \(token.name), 관리자: \(admin.email)]")
        return request.redirect(to: "/admin/workers")
    }

    // MARK: - 워커 릴리스

    /// 관리자가 워커 번들을 올린다 (ADR-0042).
    @Sendable
    func uploadWorkerRelease(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let form = try request.content.decode(WorkerReleaseForm.self)

        guard let file = form.bundle, file.data.readableBytes > 0 else {
            return try await redirectWithError("올릴 zip 을 고르세요.", on: request)
        }
        do {
            try await WorkerReleaseService.accept(
                version: form.version ?? "",
                data: Data(buffer: file.data),
                makeCurrent: form.makeCurrent != nil,
                by: admin,
                storage: request.application.artifactStorage,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError {
            return try await redirectWithError(abort.reason, on: request)
        }
        return request.redirect(to: "/admin/workers")
    }

    /// 이 릴리스를 지금 배포할 것으로 만든다. 되돌릴 때도 같은 길이다.
    @Sendable
    func deployWorkerRelease(request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let release = try await findWorkerRelease(on: request)
        try await WorkerReleaseService.makeCurrent(release, on: request.db)
        request.logger.notice("워커 릴리스를 배포로 바꿨습니다 [버전: \(release.version)]")
        return request.redirect(to: "/admin/workers")
    }

    @Sendable
    func deleteWorkerRelease(request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let release = try await findWorkerRelease(on: request)
        do {
            try await WorkerReleaseService.remove(
                release,
                storage: request.application.artifactStorage,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError {
            return try await redirectWithError(abort.reason, on: request)
        }
        return request.redirect(to: "/admin/workers")
    }

    private func findWorkerRelease(on request: Request) async throws -> WorkerRelease {
        guard let id = request.parameters.get("releaseID", as: UUID.self),
              let release = try await WorkerRelease.find(id, on: request.db)
        else {
            throw Abort(.notFound, reason: "릴리스를 찾을 수 없습니다.")
        }
        return release
    }

    /// 오류를 화면 위에 띄운 채로 워커 화면을 다시 그린다.
    private func redirectWithError(
        _ message: String,
        status: HTTPStatus = .badRequest,
        on request: Request
    ) async throws -> Response {
        let view = try await renderWorkers(issued: nil, error: message, on: request)
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
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
                page: try await request.pageContext(adminTab: .stats),
                recentDays: DownloadStats.recentDays,
                totalDownloads: overview.totalDownloads,
                recentDownloads: overview.recentDownloads,
                activePeople: overview.activePeople,
                apps: overview.rows.map { row in
                    StatsRow(
                        id: row.appID.uuidString,
                        name: row.appName,
                        // 확정 전 임시값은 보여주지 않는다 (ADR-0034). 통계에 잡히려면
                        // 다운로드가 있어야 하고 그러려면 출시돼 있어야 하니 실제로는
                        // 거의 안 걸리지만, 임시값이 새는 자리를 남겨두지 않는다.
                        bundleID: AppRegistration.isProvisional(row.bundleID)
                            ? "확인 중"
                            : row.bundleID,
                        total: row.total,
                        recent: row.recent,
                        people: row.people,
                        rating: ratings[row.appID]?.displayAverage
                    )
                }
            )
        ).get()
    }

    // MARK: - 앱 서명 (Apple 개발자 포털 현황)

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
        let registered = Set(try await App.query(on: request.db).all().map(\.bundleID))
        let grouped = PortalGrouping.split(certificates: certificates)
        let groupedIDs = PortalGrouping.split(bundleIDs: bundleIDs, covering: registered)

        return try await request.view.render(
            "admin-portal",
            PortalPageContext(
                page: try await request.pageContext(adminTab: .portal),
                isConfigured: request.application.alleyConfig.appStoreConnect != nil,
                signingCertificates: grouped.signing,
                otherCertificates: grouped.other,
                otherExpiringSoon: grouped.otherExpiringSoon,
                storeBundleIDs: groupedIDs.store,
                otherBundleIDs: groupedIDs.other,
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
    /// 꺼짐을 나타내는 방법이 둘이다. 체크박스는 꺼져 있으면 아예 안 보내고(nil),
    /// 라디오는 "안 하겠다" 쪽을 골라도 보낸다(`""`). 둘 다 꺼짐이므로 `isOn` 으로 읽는다.
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
        // **지금 상태를 그대로 그린다.** 예전에는 늘 nil 이었다. 확인 체크박스일
        // 때는 그것이 맞았다. 저장할 때마다 다시 확인하게 하는 것이 목적이었으니까.
        //
        // 지금은 "도메인만 / 누구나" 둘 중 하나를 고르는 자리다. 여기서 nil 을 두면
        // 이미 누구나 열어둔 스토어가 화면에서는 제한된 것처럼 보이고, 아무것도 안
        // 고치고 저장만 눌러도 "도메인을 비우려면 확인이 필요합니다" 로 거절당한다.
        //
        // 실수로 여는 것은 여전히 막힌다. 도메인 칸을 잘못 비우면 고른 쪽은 "도메인만"
        // 이라 서버가 거절하고, 열려면 라디오를 직접 옮겨야 한다.
        self.confirmOpenToAnyDomain = settings.allowedEmailDomains.isEmpty ? "on" : nil
    }

    /// 폼이 보낸 값이 "켜짐" 인가.
    ///
    /// 체크박스(안 보냄/`on`)와 라디오(`""`/`on`)를 같은 자리에서 읽는다.
    private func isOn(_ value: String?) -> Bool {
        value?.isEmpty == false
    }

    func toRequest() -> UpdateStoreSettingsRequest {
        UpdateStoreSettingsRequest(
            storeName: storeName ?? "",
            // 로고 주소는 화면에 칸이 없다. `?? ""` 로 두면 저장할 때마다
            // `STORE_LOGO_URL` 로 넣어둔 값이 조용히 지워진다. nil 은 "그대로 둔다" 다.
            logoURL: logoURL,
            accentColor: accentColor ?? "",
            allowedEmailDomains: (allowedEmailDomains ?? "").split(separator: ",").map(String.init),
            bundleIDPrefix: bundleIDPrefix ?? "",
            // 폼은 화면에 있는 모든 항목을 한 번에 보낸다. 값이 없으면 껐다는 뜻이다.
            //
            // **`!= nil` 로는 모자란다.** 체크박스는 꺼져 있으면 아예 안 보내지만,
            // 라디오는 어느 쪽을 골랐든 늘 보낸다. "제한하지 않겠다" 쪽은 빈 문자열을
            // 보내는데 그것도 nil 이 아니어서, 끄려고 고른 것이 켠 것으로 읽혔다.
            enforceBundleIDPrefix: isOn(enforceBundleIDPrefix),
            allowsAnonymousFeedback: isOn(allowsAnonymousFeedback),
            confirmOpenToAnyDomain: isOn(confirmOpenToAnyDomain)
        )
    }
}

extension StoreSettingsFormValues: Content {}

struct StoreSettingsPageContext: Encodable {
    var page: PageContext
    var values: StoreSettingsFormValues
    var branding: [BrandingSlot]
    var error: String?
    var saved: Bool
}

/// 이미지 하나를 올리는 폼이 보내는 값.
///
/// 종류는 경로에 있고 여기 없다. 폼이 종류를 실어 보내면 화면의 어느 칸에서 올렸는지와
/// 서버가 무엇으로 받았는지가 갈라질 수 있다.
struct BrandingUploadForm: Content {
    var image: File?
    /// 끝나고 돌아갈 화면. 같은 폼을 두 화면이 쓴다.
    var returnPath: String?
}

/// 화면에 그리는 이미지 칸 하나.
///
/// 올린 것이 있으면 미리보기와 크기를, 없으면 무엇을 올려야 하는지를 보여준다.
/// 둘을 같은 타입으로 두는 이유는 템플릿에서 갈라 쓰지 않으려는 것이다.
struct BrandingSlot: Encodable {
    var kind: String
    var label: String
    /// 화면에 그릴 그림의 주소.
    ///
    /// 올린 것이 없으면 제품 기본 그림을 가리킨다. 서버가 그 주소로 기본 그림을
    /// 내주므로(`DefaultBranding`) "없음" 이라고 적어두면 화면과 실제가 어긋난다.
    var imageURL: String?
    /// 지금 보이는 것이 제품 기본 그림인가. 그때는 지울 것이 없다.
    var isDefault: Bool
    /// `1024×1024 · 240KB` 처럼 한 줄로 적은 지금 상태.
    var summary: String?
    /// `1024×1024 PNG 를 권합니다` 처럼 무엇을 올려야 하는지.
    var requirement: String
    /// 브라우저가 고른 순간 검사할 수 있게 넘기는 규칙. `atLeast:32` 또는
    /// `exactly:512,1024` 꼴이다 (`Public/image-check.js`).
    var rule: String

    static func rows(
        for kinds: [BrandingAssetKind],
        assets: [BrandingAssetKind: BrandingAsset]
    ) -> [BrandingSlot] {
        kinds.map { kind in
            let asset = assets[kind]
            return BrandingSlot(
                kind: kind.rawValue,
                label: kind.label,
                imageURL: asset?.versionedPath ?? DefaultBranding.path(for: kind),
                isDefault: asset == nil,
                summary: asset.map {
                    "\($0.width)×\($0.height) · \(Self.readableSize($0.byteCount))"
                } ?? "제품 기본 그림",
                requirement: "정사각형 PNG · \(kind.sizeRule.requirement)",
                rule: kind.sizeRule.scriptRule
            )
        }
    }

    private static func readableSize(_ bytes: Int) -> String {
        bytes < 1024 * 1024
            ? "\(max(1, bytes / 1024))KB"
            : String(format: "%.1fMB", Double(bytes) / 1024 / 1024)
    }
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

/// 워커 번들을 올리는 폼.
struct OperatorTokenForm: Content {
    var name: String?
}

/// 발급 직후 한 번만 보여주는 운영 토큰.
struct IssuedOperatorToken: Encodable {
    var value: String
}

/// 화면에 뿌리는 운영 토큰 한 줄.
struct OperatorTokenRow: Encodable {
    var id: String
    var name: String
    /// 언제 발급한 것인지. 목록을 이 값으로 정렬하므로 화면에도 보여준다.
    ///
    /// 이름만 보여주던 때는 폐기하고 다시 발급한 토큰과 원래 있던 토큰이 화면에서
    /// 똑같이 보였다. 둘 다 쓴 적이 없으면 구별할 단서가 하나도 없었다.
    var issuedAt: DisplayDate
    var lastUsed: DisplayDate?
    var isActive: Bool

    init(token: OperatorToken) throws {
        self.id = try token.requireID().uuidString
        self.name = token.name
        self.issuedAt = DateStyle.minute.display(from: token.createdAt ?? Date())
        self.lastUsed = token.lastUsedAt.map { DateStyle.minute.display(from: $0) }
        self.isActive = token.isActive
    }
}

struct WorkerReleaseForm: Content {
    var version: String?
    var bundle: File?
    /// 체크하면 올리자마자 배포한다. 안 하면 보관만 한다.
    var makeCurrent: String?
}

/// 화면에 뿌리는 릴리스 한 줄.
struct WorkerReleaseRow: Encodable {
    var id: String
    var version: String
    var size: String
    var uploadedAt: DisplayDate
    var isCurrent: Bool

    init(release: WorkerRelease) throws {
        self.id = try release.requireID().uuidString
        self.version = release.version
        self.size = ByteCount.humanReadable(release.fileSize)
        self.uploadedAt = DateStyle.minute.display(from: release.createdAt ?? Date())
        self.isCurrent = release.isCurrent
    }
}

struct WorkerRow: Encodable {
    var id: String
    var name: String
    /// 언제 등록한 것인지. 이름이 같은 워커를 구별할 단서다 (`OperatorTokenRow` 참고).
    var registeredAt: DisplayDate
    var osVersion: String?
    var lastSeen: DisplayDate?
    var isBusy: Bool
    var isActive: Bool
    /// 이 워커가 알린 버전. 모르면 "모름" 으로 그린다 (ADR-0042).
    var workerVersion: String
    /// 서버가 아는 것보다 낡았나. **모름도 낡음으로 친다.**
    ///
    /// 버전을 안 알리는 워커는 그 필드가 생기기 전 것이고, 그건 이미 한참 낡았다는
    /// 뜻이다. 이번에 dmg 를 zip 으로 풀던 워커가 정확히 그랬다.
    var isStale: Bool

    init(worker: Worker) throws {
        self.id = worker.id?.uuidString ?? ""
        self.name = worker.name
        self.registeredAt = DateStyle.minute.display(from: worker.createdAt ?? Date())
        self.osVersion = worker.osVersion
        self.lastSeen = worker.lastSeenAt.map { DateStyle.minute.display(from: $0) }
        self.isBusy = worker.currentJobID != nil
        self.isActive = worker.isActive
        self.workerVersion = worker.workerVersion ?? "모름"
        if let reported = worker.workerVersion {
            self.isStale = WorkerVersion.isOlder(reported, than: WorkerVersion.current)
        } else {
            self.isStale = true
        }
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
    var lastSeen: DisplayDate?
    /// 실패 이유. 왜 멈췄는지가 여기 남는다.
    var note: String?
    /// 무엇 때문인지 한 줄로. 갈래를 모르면 nil.
    var failureTitle: String?
    /// 무엇을 해야 하는지.
    var failureAdvice: String?
    /// 지원 문의에 적을 코드. 문장 옆에 작게 보여준다.
    var failureCode: String?
    /// 쌓아둔 단계별 로그. 실패 직전에 무엇을 하고 있었는지가 여기 있다.
    var log: String?

    init(job: SigningJob) {
        let version = job.$version.value
        self.app = version?.$app.value?.name ?? "?"
        self.version = version.map { "\($0.shortVersion) (\($0.buildNumber))" } ?? "?"
        self.state = Self.stateName(job.state)
        self.attempt = job.attempt
        self.lastSeen = (job.heartbeatAt ?? job.claimedAt).map { DateStyle.minute.display(from: $0) }
        self.note = job.failureReason
        // 코드를 그대로 내보내지 않는다. 사람이 읽는 문장과 함께만 보여준다 (ADR-0023).
        self.failureTitle = job.failureCode.map(SigningFailureGuidance.title)
        self.failureAdvice = job.failureCode.map(SigningFailureGuidance.whatToDo)
        self.failureCode = job.failureCode?.rawValue
        self.log = (job.log?.isEmpty == false) ? job.log : nil
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
/// 앱 서명 화면이 무엇을 펼치고 무엇을 접을지 가른다.
///
/// 화면 밖에 두는 이유는 시험 때문이다. Apple 과 이야기하지 않고도 분류만 따로
/// 확인할 수 있어야 한다.
enum PortalGrouping {
    /// 이만큼 남았으면 갱신을 시작해야 한다. 인증서 갱신은 사람의 손이 여러 번 든다.
    static let expiringSoonDays = 30

    struct Certificates {
        var signing: [CertificateRow]
        var other: [CertificateRow]
        /// 접어둔 것 중 곧 만료되는 수. 접힌 채로도 그 사실은 알려야 한다.
        var otherExpiringSoon: Int
    }

    static func split(certificates: [CertificateRow]) -> Certificates {
        let other = certificates.filter { !$0.isDeveloperID }
        return Certificates(
            signing: certificates.filter(\.isDeveloperID),
            other: other,
            otherExpiringSoon: other.count { ($0.daysLeft ?? .max) < expiringSoonDays }
        )
    }

    struct BundleIDs {
        var store: [ASCBundleID]
        var other: [ASCBundleID]
    }

    /// App ID 가 이 스토어와 이어지는지는 **스토어에 등록된 앱**으로 판정한다.
    ///
    /// 플랫폼으로는 갈리지 않는다. Apple 에 `filter[platform]=MAC_OS` 를 걸어도 iOS
    /// 앱의 App ID 가 함께 온다. 번들 ID 접두사로도 갈리지 않는다. 한 조직은 iOS 앱과
    /// 맥 앱에 같은 접두사를 쓴다. 남는 기준은 "이 스토어가 실제로 다루는 앱인가" 뿐이다.
    static func split(
        bundleIDs: [ASCBundleID],
        covering registered: Set<String>
    ) -> BundleIDs {
        var store: [ASCBundleID] = []
        var other: [ASCBundleID] = []
        for bundleID in bundleIDs {
            // **`*` 하나는 빼고 본다.** 그것은 무엇이든 덮으므로 어떤 기준을 들어도
            // 늘 통과한다. Xcode 가 만들어두는 항목이라 이 스토어를 위해 만든 것도
            // 아니다. 통과시키면 "이 스토어의 App ID" 라는 말이 뜻을 잃는다.
            let coversEverything = bundleID.identifier == "*"
            if !coversEverything, registered.contains(where: bundleID.covers) {
                store.append(bundleID)
            } else {
                other.append(bundleID)
            }
        }
        return BundleIDs(store: store, other: other)
    }
}

struct CertificateRow: Encodable {
    var name: String
    var type: String
    var expires: DisplayDate?
    var daysLeft: Int?
    /// 서명에 쓰는 인증서인지. 이게 만료되면 워커가 멈춘다.
    var isDeveloperID: Bool
    /// 만료됐거나 곧 만료된다. 화면에서 눈에 띄게 한다.
    var needsAttention: Bool

    init(certificate: ASCCertificate) {
        self.name = certificate.name
        self.type = certificate.type
        self.expires = certificate.expiresAt.map { DateStyle.day.display(from: $0) }
        let days = certificate.daysUntilExpiry()
        self.daysLeft = days
        self.isDeveloperID = certificate.isDeveloperID
        // 인증서 갱신은 사람의 손이 여러 번 필요한 일이다. 한 달 전에는 알아야 한다.
        self.needsAttention =
            certificate.isDeveloperID && (days ?? .max) < PortalGrouping.expiringSoonDays
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
    /// 서명에 쓰는 인증서. 이 화면의 본론이다.
    var signingCertificates: [CertificateRow]
    /// 팀의 나머지 인증서.
    ///
    /// **접어둔다.** iOS 개발 인증서는 각자의 Xcode 가 관리하고, 여기서 만료를 봐도
    /// 이 스토어에서 할 수 있는 일이 없다. 열 몇 줄이 서명용 한 줄을 덮는다.
    var otherCertificates: [CertificateRow]
    /// 접어둔 것 중 곧 만료되는 수. 접힌 채로도 그 사실은 알린다.
    var otherExpiringSoon: Int
    /// 이 스토어의 앱을 덮는 App ID.
    var storeBundleIDs: [ASCBundleID]
    /// 팀의 나머지 App ID. 같은 이유로 접어둔다.
    var otherBundleIDs: [ASCBundleID]
    /// 스토어 설정의 프리픽스로 만든 와일드카드 제안값.
    var suggestedWildcard: String?
    /// Apple 과 이야기하지 못한 이유.
    var connectionError: String?
    /// 사람이 고칠 수 있는 실패.
    var error: String?
}

struct WorkerListPageContext: Encodable {
    var page: PageContext
    /// 지금 쓰는 워커. 폐기한 것은 여기 없다.
    var workers: [WorkerRow]
    /// 폐기한 워커. 화면에서는 접어둔다.
    var revokedWorkers: [WorkerRow]
    var jobs: [SigningJobRow]
    var issued: IssuedWorkerToken?
    var error: String?
    /// 이 서버가 아는 워커 버전. 낡은 워커를 가릴 기준이다 (ADR-0042).
    var serverWorkerVersion: String
    var releases: [WorkerReleaseRow]
    /// 운영 파이프라인이 쓰는 토큰들 (ADR-0043).
    var operatorTokens: [OperatorTokenRow]
    /// 폐기한 운영 토큰. 워커와 같은 이유로 접어둔다.
    var revokedOperatorTokens: [OperatorTokenRow]
    /// 방금 발급한 토큰. 한 번만 보여준다.
    var issuedOperatorToken: IssuedOperatorToken?
}
