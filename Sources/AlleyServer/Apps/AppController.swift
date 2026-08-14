import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 등록·조회·수정과 앱별 업로드 권한 관리.
public struct AppController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        // 앱 정보는 전부 로그인한 사람에게만 보인다. 사내 배포용이라
        // 어떤 앱이 있는지 자체가 공개할 정보가 아니다.
        let authenticated = routes.grouped(SessionAuthenticator(), User.guardMiddleware())

        authenticated.get(APIPath.apps.pathComponents, use: list)
        authenticated.post(APIPath.apps.pathComponents, use: create)
        authenticated.get(APIPath.bundleIDs.pathComponents, use: bundleIDLedger)

        let single = authenticated.grouped(APIPath.apps.pathComponents).grouped(":appID")
        single.get(use: detail)
        single.patch(use: update)

        let members = single.grouped("members")
        members.get(use: listMembers)
        members.post(use: addMember)
        members.delete(":userID", use: removeMember)
    }

    // MARK: - 목록

    /// 앱 목록.
    ///
    /// 일반 사용자에게는 출시본이 있는 앱만 보인다. 아직 출시하지 않은 앱이
    /// 목록에 뜨면 받을 수 없는 앱을 보고 문의하게 된다.
    /// 개발자와 관리자는 준비 중인 앱까지 본다.
    @Sendable
    func list(request: Request) async throws -> [AppDTO] {
        let user = try request.requireUser()
        let apps = try await App.query(on: request.db).sort(\.$name).all()
        let latest = try await latestReleasedVersions(on: request.db)

        return try apps.compactMap { app in
            let released = latest[try app.requireID()]
            guard released != nil || user.role.canPublish else { return nil }
            return try app.toDTO(latestReleased: released)
        }
    }

    /// 번들 ID 대장.
    ///
    /// 새 앱을 만들기 전에 어떤 ID 가 이미 쓰이는지 스스로 확인하라고 내려준다.
    /// 등록을 시도해서 409 를 받고서야 아는 것보다 낫다.
    @Sendable
    func bundleIDLedger(request: Request) async throws -> [BundleIDEntry] {
        _ = try request.requireUser()
        let apps = try await App.query(on: request.db)
            .with(\.$owner)
            .sort(\.$bundleID)
            .all()

        return try apps.map { app in
            BundleIDEntry(
                bundleID: app.bundleID,
                appID: try app.requireID(),
                appName: app.name,
                ownerEmail: app.owner.email
            )
        }
    }

    // MARK: - 등록

    @Sendable
    func create(request: Request) async throws -> Response {
        let user = try request.requirePublisher()
        let payload = try request.content.decode(CreateAppRequest.self)
        let config = request.application.alleyConfig

        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "앱 이름이 비어 있습니다.")
        }

        let bundleID = payload.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateBundleID(bundleID, config: config, logger: request.logger)

        // 형식이 맞아도 이미 쓰는 ID 면 안 된다. 같은 번들 ID 를 가진 앱이 둘이면
        // macOS 쪽에서 어느 쪽이 설치돼 있는지 구분할 방법이 없다.
        if try await App.query(on: request.db).filter(\.$bundleID == bundleID).first() != nil {
            throw Abort(.conflict, reason: "번들 ID '\(bundleID)' 는 이미 등록돼 있습니다.")
        }

        let app = App(
            bundleID: bundleID,
            name: name,
            summary: payload.summary,
            details: payload.description,
            category: payload.category,
            ownerID: try user.requireID()
        )

        do {
            try await app.save(on: request.db)
        } catch {
            // 위 조회와 저장 사이에 다른 요청이 같은 ID 를 넣었을 수 있다.
            // 유니크 제약이 최종 방어선이고, 여기서 사용자가 읽을 문장으로 바꾼다.
            if try await App.query(on: request.db).filter(\.$bundleID == bundleID).first() != nil {
                throw Abort(.conflict, reason: "번들 ID '\(bundleID)' 는 이미 등록돼 있습니다.")
            }
            throw error
        }

        let response = Response(status: .created)
        try response.content.encode(try app.toDTO())
        return response
    }

    private func validateBundleID(
        _ bundleID: String,
        config: AppConfig,
        logger: Logger
    ) throws {
        do {
            try BundleIdentifier.validate(
                bundleID,
                requiredPrefix: config.store.bundleIDPrefix
            )
        } catch {
            // `validate` 는 타입이 붙은 오류를 던지므로 error 는 ValidationError 다.
            // 프리픽스는 조직의 정책이라 경고만 하고 넘어가도록 설정할 수 있다.
            // 형식 오류는 정책이 아니라 사실이라 언제나 막는다.
            if case .prefixMismatch = error, !config.store.enforceBundleIDPrefix {
                logger.notice("번들 ID 프리픽스 규칙에서 벗어난 등록: \(bundleID)")
                return
            }
            throw Abort(.badRequest, reason: error.description)
        }
    }

    // MARK: - 상세 / 수정

    @Sendable
    func detail(request: Request) async throws -> AppDTO {
        _ = try request.requireUser()
        let app = try await request.findApp()
        let latest = try await latestReleasedVersion(ofApp: try app.requireID(), on: request.db)
        return try app.toDTO(latestReleased: latest)
    }

    @Sendable
    func update(request: Request) async throws -> AppDTO {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let payload = try request.content.decode(UpdateAppRequest.self)
        if let name = payload.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "앱 이름이 비어 있습니다.")
            }
            app.name = trimmed
        }
        // 빈 문자열로 지우는 것과 항목을 안 보낸 것을 구분한다.
        if let summary = payload.summary { app.summary = summary.isEmpty ? nil : summary }
        if let details = payload.description { app.details = details.isEmpty ? nil : details }
        if let category = payload.category { app.category = category.isEmpty ? nil : category }
        if let iconURL = payload.iconURL { app.iconURL = iconURL.isEmpty ? nil : iconURL }

        try await app.save(on: request.db)

        let latest = try await latestReleasedVersion(ofApp: try app.requireID(), on: request.db)
        return try app.toDTO(latestReleased: latest)
    }

    // MARK: - 멤버

    @Sendable
    func listMembers(request: Request) async throws -> [AppMemberDTO] {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        let owner = try await app.$owner.get(on: request.db)
        let members = try await AppMember.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .with(\.$user)
            .all()

        let ownerID = try owner.requireID()
        return try [AppMemberDTO(user: owner.toDTO(), isOwner: true)]
            + members
            .filter { $0.$user.id != ownerID }
            .map { AppMemberDTO(user: try $0.user.toDTO(), isOwner: false) }
    }

    @Sendable
    func addMember(request: Request) async throws -> [AppMemberDTO] {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let payload = try request.content.decode(AddAppMemberRequest.self)
        let email = payload.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 한 번도 로그인하지 않은 사람은 아직 계정이 없다. 미리 초대장을 만들지 않는다.
        // 없는 이메일을 넣어두면 오타를 알아챌 방법이 없다.
        guard let target = try await User.query(on: request.db)
            .filter(\.$email == email)
            .first()
        else {
            throw Abort(.notFound, reason: "'\(email)' 계정을 찾을 수 없습니다. 먼저 한 번 로그인해야 합니다.")
        }

        let targetID = try target.requireID()
        let appID = try app.requireID()

        // 오너는 표에 없어도 항상 올릴 수 있다. 중복해서 넣을 이유가 없다.
        if app.$owner.id != targetID {
            let existing = try await AppMember.query(on: request.db)
                .filter(\.$app.$id == appID)
                .filter(\.$user.$id == targetID)
                .first()
            if existing == nil {
                try await AppMember(appID: appID, userID: targetID).save(on: request.db)
            }
        }

        return try await listMembers(request: request)
    }

    @Sendable
    func removeMember(request: Request) async throws -> HTTPStatus {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        guard let targetID = request.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "사용자 ID 형식이 올바르지 않습니다.")
        }
        guard app.$owner.id != targetID else {
            throw Abort(.badRequest, reason: "앱 오너는 멤버에서 뺄 수 없습니다.")
        }

        try await AppMember.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .filter(\.$user.$id == targetID)
            .delete()
        return .noContent
    }

    // MARK: - 최신 출시본 조회

    /// 앱마다 가장 높은 빌드 번호의 출시본을 한 번의 쿼리로 모은다.
    ///
    /// 앱마다 따로 조회하면 목록 화면에서 N+1 이 된다.
    private func latestReleasedVersions(on database: any Database) async throws -> [UUID: Version] {
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

    private func latestReleasedVersion(ofApp appID: UUID, on database: any Database) async throws -> Version? {
        try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .filter(\.$state == .released)
            .sort(\.$buildNumber, .descending)
            .with(\.$artifacts)
            .first()
    }
}

extension AppDTO: Content {}
extension BundleIDEntry: Content {}
extension AppMemberDTO: Content {}
