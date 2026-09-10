import AlleyShared
import Fluent
import Foundation
import Vapor

/// 버전 생성·업로드 완료 통지·출시·다운로드.
///
/// 바이너리는 이 서버를 거치지 않는다. 업로드도 다운로드도 만료 있는 URL 을 내주고
/// 클라이언트가 스토리지와 직접 주고받는다. 서버는 "무엇이 어디 있고 어떤
/// 상태인가"만 관리한다.
public struct VersionController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        // 사람의 세션과 CI 의 배포 토큰이 나란히 선다. 둘 다 막지 않고 붙이기만 하며,
        // 무엇이 필요한지는 핸들러마다 다르다. 다운로드는 사람만 할 수 있고
        // (이력에 사용자를 남긴다), 업로드는 양쪽 다 할 수 있다 (ADR-0015).
        let authenticated = routes.grouped(SessionAuthenticator(), DeployTokenAuthenticator())

        let ofApp = authenticated
            .grouped(APIPath.apps.pathComponents)
            .grouped(":appID", "versions")
        ofApp.get(use: list)
        ofApp.post(use: create)

        let single = authenticated
            .grouped(APIPath.apiRoot.pathComponents)
            .grouped("versions", ":versionID")
        single.get(use: detail)
        single.post("complete", use: completeUpload)
        single.post("release", use: release)
        single.delete("release", use: unrelease)
        single.get("download", use: download)
    }

    // MARK: - 목록 / 상세

    /// 앱의 버전 목록. 최신 빌드가 위로 온다.
    ///
    /// 올릴 권한이 없는 사람에게는 출시본만 보인다. 준비 중인 버전 번호가
    /// 새어나가면 출시 전에 알려지지 않아야 할 일정이 드러난다.
    @Sendable
    func list(request: Request) async throws -> [VersionDTO] {
        let app = try await request.findApp()
        let canSeeAll = try await request.uploadRights(to: app) != nil

        var query = try Version.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .with(\.$artifacts)
            .sort(\.$buildNumber, .descending)

        if !canSeeAll {
            query = query.filter(\.$state == .released)
        }

        return try await query.all().map { try $0.toDTO() }
    }

    @Sendable
    func detail(request: Request) async throws -> VersionDTO {
        let version = try await request.findVersion()

        if version.state.isPubliclyVisible {
            // 출시본은 받을 사람 누구나 본다. 다만 로그인은 해야 한다.
            guard request.deployToken != nil || request.auth.has(User.self) else {
                throw Abort(.unauthorized, reason: "인증이 필요합니다.")
            }
        } else {
            _ = try await request.requireUploadRights(to: version.app)
        }
        return try version.toDTO()
    }

    // MARK: - 생성

    /// 버전 메타데이터를 만들고 업로드할 자리를 내준다.
    ///
    /// 이 시점에는 바이너리가 없으므로 `draft` 다. 클라이언트가 실제로 올린 뒤
    /// `complete` 를 불러야 `uploaded` 로 넘어간다.
    @Sendable
    func create(request: Request) async throws -> Response {
        let app = try await request.findApp()
        let principal = try await request.requireUploadRights(to: app)

        let payload = try request.content.decode(CreateVersionRequest.self)
        let shortVersion = payload.shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortVersion.isEmpty else {
            throw Abort(.badRequest, reason: "버전 문자열이 비어 있습니다.")
        }
        guard payload.buildNumber > 0 else {
            throw Abort(.badRequest, reason: "빌드 번호는 1 이상이어야 합니다.")
        }

        let appID = try app.requireID()
        // 빌드 번호가 겹치면 macOS 가 어느 쪽이 최신인지 판단할 수 없다.
        if try await Version.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$buildNumber == payload.buildNumber)
            .first() != nil
        {
            throw Abort(.conflict, reason: "빌드 번호 \(payload.buildNumber) 는 이미 쓰였습니다.")
        }

        let version = Version(
            appID: appID,
            shortVersion: shortVersion,
            buildNumber: payload.buildNumber,
            releaseNotes: payload.releaseNotes,
            minimumOSVersion: payload.minimumOSVersion,
            // 올린 사람에게 서명 여부를 묻지 않는다. 워커가 번들을 열어보고
            // 판정한다 (ADR-0035). 올라오는 파일은 늘 "올라온 그대로" 다.
            uploadKind: .unsigned,
            entitlements: try Self.checkedEntitlements(payload.entitlements),
            createdByID: try principal.attributedUserID
        )
        try await version.save(on: request.db)

        request.logger.notice(
            "버전 생성 [\(app.bundleID) \(shortVersion) (\(payload.buildNumber)), 올린 쪽: \(principal.description)]"
        )

        let key = request.artifactStorage.newKey(
            ArtifactStorage.objectKey(
                appID: appID,
                versionID: try version.requireID(),
                kind: version.uploadKind.artifactKind
            )
        )
        let presigned = try await request.artifactStorage.uploadURL(key: key)

        // 방금 만들어서 아티팩트가 없다. toDTO 가 관계를 읽으려 하지 않도록 채워둔다.
        version.$artifacts.value = []

        let response = Response(status: .created)
        try response.content.encode(
            UploadTicket(
                version: try version.toDTO(),
                uploadURL: presigned.url,
                expiresAt: presigned.expiresAt
            )
        )
        return response
    }

    /// 함께 올라온 entitlements 를 **받는 자리에서** 검사한다.
    ///
    /// 서명할 때가 되어서야 깨진 plist 를 발견하면 왕복이 길다. 그때는 워커가 이미 잡을
    /// 물고 있고, 올린 사람은 몇 분 뒤에야 실패를 본다.
    ///
    /// **프로필이 필요한 권한(`com.apple.developer.*`)인지는 여기서 보지 않는다.**
    /// 그 판단은 프로비저닝 프로필이 번들 안에 있는지에 달렸는데, 이 시점에는 바이너리가
    /// 아직 올라오지도 않았다. 그 검사는 번들을 손에 쥔 워커가 한다.
    private static func checkedEntitlements(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            try EntitlementsPlist.validate(trimmed)
        } catch let error as EntitlementsPlist.PlistError {
            throw Abort(.badRequest, reason: error.description)
        }
        return trimmed
    }

    // MARK: - 업로드 완료 통지

    /// 올렸다는 통지를 받고 스토리지를 직접 확인한 뒤 상태를 넘긴다.
    ///
    /// 클라이언트 말만 믿으면 빈 버전이 출시될 수 있어서 `HEAD` 로 실제 크기를 읽는다.
    @Sendable
    func completeUpload(request: Request) async throws -> VersionDTO {
        let version = try await request.findVersion()
        _ = try await request.requireUploadRights(to: version.app)

        // 재시도는 failed 에서 다시 올리는 경로다. 이미 서명까지 간 버전을
        // 여기서 되돌리지는 않는다.
        guard version.state == .draft || version.state == .failed else {
            throw Abort(
                .conflict,
                reason: "지금은 업로드를 마칠 수 있는 상태가 아닙니다. 현재 상태: \(version.state.rawValue)"
            )
        }

        let payload = try request.content.decode(CompleteUploadRequest.self)
        let kind = version.uploadKind.artifactKind
        let key = request.artifactStorage.newKey(
            ArtifactStorage.objectKey(
                appID: version.$app.id,
                versionID: try version.requireID(),
                kind: kind
            )
        )

        guard let size = try await request.artifactStorage.head(key: key) else {
            throw Abort(.badRequest, reason: "스토리지에 올라온 파일이 없습니다. 업로드를 먼저 끝내세요.")
        }
        guard size > 0 else {
            throw Abort(.badRequest, reason: "업로드된 파일이 비어 있습니다.")
        }

        try await upsertArtifact(
            versionID: try version.requireID(),
            kind: kind,
            storageKey: key,
            sha256: payload.sha256?.lowercased(),
            fileSize: size,
            on: request.db
        )

        try version.transition(to: .uploaded)
        try await version.save(on: request.db)

        // **모든 업로드가 워커를 거친다.** 예전에는 올린 사람이 "서명·공증 완료" 를
        // 고르면 검사 없이 배포 준비됨으로 넘어갔다. 그 값을 아무도 확인하지 않아서,
        // 서명 안 된 파일을 완료로 올리면 그대로 나갔다 (ADR-0035).
        //
        // 이제 워커가 번들을 열어보고 이미 서명·공증돼 있으면 그 단계만 건너뛴다.
        // 잡을 만드는 시점이 곧 큐에 들어가는 시점이라, 이 저장이 끝나기 전에는
        // 워커가 가져갈 수 없다.
        let job = try await SigningJob.enqueue(
            versionID: try version.requireID(),
            on: request.db
        )
        request.logger.notice(
            "서명 잡 대기 [버전: \(version.shortVersion) (\(version.buildNumber)), 시도: \(job.attempt)]"
        )

        try await version.$artifacts.load(on: request.db)
        return try version.toDTO()
    }

    private func upsertArtifact(
        versionID: UUID,
        kind: ArtifactKind,
        storageKey: String,
        sha256: String?,
        fileSize: Int64,
        on database: any Database
    ) async throws {
        // 재시도하면 같은 키에 덮어쓴다. 행을 새로 만들면 유니크 제약에 걸린다.
        if let existing = try await Artifact.query(on: database)
            .filter(\.$version.$id == versionID)
            .filter(\.$kind == kind)
            .first()
        {
            existing.storageKey = storageKey
            existing.sha256 = sha256
            existing.fileSize = fileSize
            try await existing.save(on: database)
            return
        }

        try await Artifact(
            versionID: versionID,
            kind: kind,
            storageKey: storageKey,
            sha256: sha256,
            fileSize: fileSize
        ).save(on: database)
    }

    // MARK: - 출시

    @Sendable
    func release(request: Request) async throws -> VersionDTO {
        let version = try await request.findVersion()
        _ = try await request.requireUploadRights(to: version.app)

        try version.transition(to: .released)
        try await version.save(on: request.db)
        return try version.toDTO()
    }

    /// 출시 철회. 배포 가능하지만 비공개인 `ready` 로 돌아간다.
    ///
    /// 아티팩트는 지우지 않는다. 이미 받아간 사람의 앱은 계속 동작하고,
    /// 문제가 해결되면 다시 출시할 수 있어야 한다.
    @Sendable
    func unrelease(request: Request) async throws -> VersionDTO {
        let version = try await request.findVersion()
        _ = try await request.requireUploadRights(to: version.app)

        try version.transition(to: .ready)
        version.releasedAt = nil
        try await version.save(on: request.db)
        return try version.toDTO()
    }

    // MARK: - 다운로드

    /// 이력을 남기고 만료 있는 다운로드 URL 을 내준다.
    ///
    /// **배포 토큰으로는 받을 수 없다.** 이력에 사람을 남기는 것이 이 경로의 목적 중
    /// 하나인데, 파이프라인을 그 자리에 적으면 "누가 받아갔나"가 흐려진다.
    @Sendable
    func download(request: Request) async throws -> DownloadTicket {
        let user = try request.requireUser()
        let version = try await request.findVersion()

        // 출시 전 버전은 올릴 권한이 있는 사람만 받는다. 배포 전 검증용이다.
        if !version.state.isPubliclyVisible {
            try await version.app.requireUploadAccess(for: user, on: request.db)
            guard version.state == .ready else {
                throw Abort(
                    .conflict,
                    reason: "아직 받을 수 있는 상태가 아닙니다. 현재 상태: \(version.state.rawValue)"
                )
            }
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
        return DownloadTicket(
            downloadURL: presigned.url,
            expiresAt: presigned.expiresAt,
            sha256: artifact.sha256,
            fileSize: artifact.fileSize
        )
    }
}

extension UploadKind {
    /// 이 파이프라인으로 올린 파일이 스토리지에서 갖는 성격.
    public var artifactKind: ArtifactKind {
        switch self {
        case .unsigned: return .unsigned
        case .signed: return .signed
        }
    }
}

extension VersionDTO: Content {}
extension UploadTicket: Content {}
extension DownloadTicket: Content {}
extension CreateAppRequest: Content {}
extension CreateVersionRequest: Content {}
extension CompleteUploadRequest: Content {}
extension UpdateAppRequest: Content {}
extension AddAppMemberRequest: Content {}
