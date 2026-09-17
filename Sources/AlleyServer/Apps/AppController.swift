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
        let latest = try await App.latestReleasedVersions(on: request.db)
        // 앱마다 따로 세면 N+1 이 된다. 한 번에 모아 접는다.
        let ratings = try await Feedback.summaries(
            ofApps: apps.map { try $0.requireID() },
            on: request.db
        )
        // 어느 앱이 스토어 앱인지는 서버만 안다. 클라이언트가 번들 ID 로 견주면
        // 번들 ID 를 바꾼 뒤에 어긋난다 (`AppDTO.isStoreApp`).
        let storeAppID = try await request.storeAppSettings().$app.id
        let visibility = try await AppVisibility.of(user, on: request.db)

        return try apps.compactMap { app in
            let appID = try app.requireID()
            let released = latest[appID]
            // **출시된 앱은 모두에게 준다.** 이것이 스토어 앱이 그리는 카탈로그다
            // (ADR-0051). 출시 전인 것만 손댈 수 있는 사람에게 보인다.
            guard try released != nil || visibility.canTouch(app) else { return nil }
            return try app.toDTO(
                latestReleased: released,
                rating: ratings[appID],
                isStoreApp: appID == storeAppID
            )
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
        let app = try await AppRegistration.create(
            try request.content.decode(CreateAppRequest.self),
            owner: user,
            settings: try await request.storeSettings(),
            on: request.db,
            logger: request.logger
        )

        let response = Response(status: .created)
        try response.content.encode(try app.toDTO())
        return response
    }

    // MARK: - 상세 / 수정

    @Sendable
    func detail(request: Request) async throws -> AppDTO {
        _ = try request.requireUser()
        let app = try await request.findApp()
        let appID = try app.requireID()
        let latest = try await App.latestReleasedVersion(ofApp: appID, on: request.db)
        let rating = try await Feedback.summary(ofApp: appID, on: request.db)
        return try app.toDTO(latestReleased: latest, rating: rating)
    }

    @Sendable
    func update(request: Request) async throws -> AppDTO {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        try await AppRegistration.update(
            app,
            with: try request.content.decode(UpdateAppRequest.self),
            on: request.db
        )

        let latest = try await App.latestReleasedVersion(ofApp: try app.requireID(), on: request.db)
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
}

extension AppDTO: Content {}
extension BundleIDEntry: Content {}
extension AppMemberDTO: Content {}
