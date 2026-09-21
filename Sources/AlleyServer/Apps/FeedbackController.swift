import AlleyShared
import Fluent
import Foundation
import Vapor

/// 별점과 피드백.
///
/// **받아본 사람만 남길 수 있다.** 안 써본 앱에 별점을 주는 것은 정보가 아니다.
/// 다운로드 이력이 이미 있으므로(ADR-0009) 그것을 조건으로 쓴다.
public struct FeedbackController: RouteCollection, Sendable {
    /// 스크린샷 크기 상한.
    ///
    /// 앱 바이너리와 달리 이 파일은 서버가 직접 받는다. 이유는 ADR-0016 에 있다.
    static let maximumScreenshotSize = 8 * 1024 * 1024

    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let authenticated = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apiRoot.pathComponents)

        authenticated.get("apps", ":appID", "feedback", use: list)
        authenticated.post("versions", ":versionID", "feedback", use: submit)
        authenticated.delete("feedback", ":feedbackID", use: remove)

        // 스크린샷만 본문이 크다. 이 경로에만 따로 상한을 준다.
        authenticated.on(
            .POST,
            "feedback", ":feedbackID", "screenshot",
            body: .collect(maxSize: .init(value: Self.maximumScreenshotSize)),
            use: attachScreenshot
        )
    }

    // MARK: - 조회

    /// 앱 하나에 달린 피드백 전부. 최근 것이 위로 온다.
    @Sendable
    func list(request: Request) async throws -> [FeedbackDTO] {
        let user = try request.requireUser()
        let app = try await request.findApp()

        let entries = try await Feedback.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .with(\.$user)
            .with(\.$version)
            .sort(\.$createdAt, .descending)
            .all()

        return try await withScreenshotURLs(entries, viewer: user, on: request)
    }

    // MARK: - 남기기

    /// 별점과 글을 남기거나 고친다.
    ///
    /// 같은 버전에 두 번째로 부르면 앞의 것을 고친다. 사람 하나가 같은 빌드에 대해
    /// 두 번 말할 이유가 없고, 생각이 바뀌면 고치는 것이 자연스럽다.
    @Sendable
    func submit(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let version = try await request.findVersion()
        let payload = try request.content.decode(SubmitFeedbackRequest.self)

        let entry = try await FeedbackSubmission.submit(
            payload,
            to: version,
            by: user,
            settings: try await request.storeSettings(),
            on: request.db
        )

        // 알림이 실패해도 남긴 글은 남는다.
        await announce(entry, version: version, by: user, on: request)

        try await entry.$version.load(on: request.db)
        try await entry.$user.load(on: request.db)

        let response = Response(status: .created)
        try response.content.encode(try entry.toDTO(viewer: user))
        return response
    }

    /// 스크린샷을 붙인다.
    ///
    /// 글을 먼저 남기고 그 뒤에 붙인다. 한 번에 받으면 multipart 를 다뤄야 하는데,
    /// 이미지가 없는 경우가 대부분이라 그 복잡도를 늘 지고 가게 된다.
    @Sendable
    func attachScreenshot(request: Request) async throws -> FeedbackDTO {
        let user = try request.requireUser()
        let entry = try await request.findFeedback()
        guard entry.$user.id == (try user.requireID()) else {
            throw Abort(.forbidden, reason: "내가 남긴 피드백에만 붙일 수 있습니다.")
        }

        guard let buffer = request.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "이미지가 비어 있습니다.")
        }
        guard let contentType = request.headers.contentType,
              contentType.type == "image"
        else {
            throw Abort(.badRequest, reason: "이미지만 붙일 수 있습니다.")
        }

        let key = request.artifactStorage.newKey(
            Feedback.screenshotKey(feedbackID: try entry.requireID())
        )
        try await request.artifactStorage.put(
            Data(buffer: buffer),
            to: key,
            contentType: contentType.serialize()
        )

        entry.screenshotKey = key
        try await entry.save(on: request.db)

        try await entry.$version.load(on: request.db)
        try await entry.$user.load(on: request.db)
        return try await single(entry, viewer: user, on: request)
    }

    // MARK: - 지우기

    /// 내가 남긴 것을 지운다. 앱 오너와 관리자도 지울 수 있다.
    ///
    /// 오너에게 지울 권한을 주는 이유는 사내 스토어이기 때문이다. 도를 넘은 글이
    /// 올라왔을 때 관리자를 부를 때까지 그대로 두는 것보다, 앱을 맡은 사람이 내릴 수
    /// 있는 편이 낫다. 대신 누가 지웠는지는 로그에 남는다.
    @Sendable
    func remove(request: Request) async throws -> HTTPStatus {
        let user = try request.requireUser()
        let entry = try await request.findFeedback()
        try await entry.$app.load(on: request.db)

        let isMine = try entry.$user.id == user.requireID()
        let canManage = try entry.app.canManage(user)
        guard isMine || canManage else {
            throw Abort(.forbidden, reason: "이 피드백을 지울 권한이 없습니다.")
        }

        if let key = entry.screenshotKey {
            try? await request.artifactStorage.delete(key: key)
        }
        try await entry.delete(on: request.db)

        if !isMine {
            request.logger.notice(
                "남의 피드백을 지웠습니다 [앱: \(entry.app.bundleID), 지운 사람: \(user.email)]"
            )
        }
        return .noContent
    }

    // MARK: - 보조

    /// 스크린샷이 있는 항목에 만료 있는 URL 을 붙인다.
    private func withScreenshotURLs(
        _ entries: [Feedback],
        viewer: User,
        on request: Request
    ) async throws -> [FeedbackDTO] {
        var result: [FeedbackDTO] = []
        for entry in entries {
            result.append(try await single(entry, viewer: viewer, on: request))
        }
        return result
    }

    private func single(
        _ entry: Feedback,
        viewer: User,
        on request: Request
    ) async throws -> FeedbackDTO {
        var url: String?
        if let key = entry.screenshotKey {
            url = try? await request.artifactStorage.downloadURL(key: key).url
        }
        return try entry.toDTO(viewer: viewer, screenshotURL: url)
    }

    /// 이 앱이 정한 곳으로 알린다 (ADR-0059).
    private func announce(
        _ entry: Feedback,
        version: Version,
        by user: User,
        on request: Request
    ) async {
        let stars = entry.rating.map { String(repeating: "★", count: $0) } ?? ""
        let who = entry.isAnonymous ? "익명" : user.name
        let versionName = "\(version.shortVersion) (\(version.buildNumber))"

        await request.notifier.notify(
            app: version.app,
            kind: .feedback,
            message: NotificationMessage(
                title: "\(version.app.name) \(versionName) 에 새 피드백",
                body: [stars, entry.body, "— \(who)"]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                link: request.consoleLink("/apps/\(version.$app.id.uuidString)")
            )
        )
    }
}

/// 피드백을 남기는 규칙.
enum FeedbackSubmission {
    static func submit(
        _ payload: SubmitFeedbackRequest,
        to version: Version,
        by user: User,
        settings: StoreSettings,
        on database: any Database
    ) async throws -> Feedback {
        let body = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBody = !(body ?? "").isEmpty

        guard payload.rating != nil || hasBody else {
            throw Abort(.badRequest, reason: "별점이나 글 중 하나는 있어야 합니다.")
        }
        if let rating = payload.rating {
            guard (1...5).contains(rating) else {
                throw Abort(.badRequest, reason: "별점은 1에서 5 사이여야 합니다.")
            }
        }
        guard version.state.isPubliclyVisible else {
            throw Abort(.conflict, reason: "아직 출시되지 않은 버전입니다.")
        }
        // 조용히 실명으로 바꾸지 않는다. 익명인 줄 알고 쓴 글에 이름이 붙는 것이
        // 이 기능에서 가장 나쁜 실패다.
        if payload.isAnonymous, !settings.allowsAnonymousFeedback {
            throw Abort(.forbidden, reason: "이 스토어는 익명 피드백을 받지 않습니다.")
        }

        let userID = try user.requireID()
        let versionID = try version.requireID()

        // 안 써본 앱에 별점을 주는 것은 정보가 아니다.
        let downloaded = try await Download.query(on: database)
            .filter(\.$user.$id == userID)
            .filter(\.$version.$id == versionID)
            .first() != nil
        guard downloaded else {
            throw Abort(.forbidden, reason: "받아본 버전에만 남길 수 있습니다.")
        }

        // 같은 버전에 두 번째면 앞의 것을 고친다.
        let existing = try await Feedback.query(on: database)
            .filter(\.$version.$id == versionID)
            .filter(\.$user.$id == userID)
            .first()

        let entry = existing ?? Feedback(
            appID: version.$app.id,
            versionID: versionID,
            userID: userID
        )
        entry.rating = payload.rating
        entry.body = hasBody ? body : nil
        entry.isAnonymous = payload.isAnonymous
        try await entry.save(on: database)
        return entry
    }
}

extension Request {
    /// 경로 파라미터의 피드백을 찾는다.
    func findFeedback() async throws -> Feedback {
        guard let id = parameters.get("feedbackID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "피드백 ID 형식이 올바르지 않습니다.")
        }
        guard let entry = try await Feedback.find(id, on: db) else {
            throw Abort(.notFound, reason: "피드백을 찾을 수 없습니다.")
        }
        return entry
    }
}

extension FeedbackDTO: Content {}
extension SubmitFeedbackRequest: Content {}
extension RatingSummary: Content {}
