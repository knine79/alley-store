import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 앱 동영상의 규칙 (이슈 #73, ADR-0079).
///
/// 화면 전환이나 동작이 핵심인 앱은 정지 화면 여러 장보다 짧은 영상 하나가 낫다.
/// **앱마다 하나다.** 스크린샷과 따로 두고, 보여줄 때는 스크린샷보다 앞에 둔다.
enum AppVideos {
    static let maximumSize = AppVideoLimits.maximumSize
    static let maximumDuration = AppVideoLimits.maximumDuration

    static func key(appID: UUID, id: UUID, format: VideoInspection.Format) -> String {
        "apps/\(appID.uuidString)/video/\(id.uuidString.lowercased()).\(format.fileExtension)"
    }

    /// 키에서 ID 를 꺼낸다. 주소의 `v` 에 쓴다.
    static func id(fromKey key: String) -> UUID? {
        guard let file = key.split(separator: "/").last,
              let stem = file.split(separator: ".").first
        else { return nil }
        return UUID(uuidString: String(stem))
    }

    enum Rejection: Error {
        case tooLarge
        case notVideo
        case unreadableDuration
        case tooLong(seconds: Double)

        /// 무엇이 틀렸고 어떻게 하면 되는지. `name` 은 사람이 고른 파일 이름이다.
        func reason(name: String?) -> String {
            // 파일 이름 뒤에는 띄어서 조사를 붙인다. 스크린샷 거절 문구와 같은 모양이다.
            let subject = name.map { $0 + " " } ?? "동영상"
            let word = name ?? "동영상"
            switch self {
            case .tooLarge:
                return "\(subject)\(Self.particle(word, "이", "가")) 50MB 를 넘습니다."
            case .notVideo:
                return "\(subject)\(Self.particle(word, "은", "는")) MP4 나 MOV 가 아닙니다."
            case .unreadableDuration:
                return "\(subject)의 길이를 읽지 못했습니다. 다른 프로그램으로 다시 저장해 보세요."
            case .tooLong(let seconds):
                return "\(subject)\(Self.particle(word, "이", "가")) 60초를 넘습니다 (\(VideoInspection.describe(seconds: seconds))). 줄여서 올리세요."
            }
        }

        /// 파일 이름 뒤에 붙일 조사. 이름은 대개 `demo.mp4` 처럼 영문·숫자로 끝나서,
        /// 그 글자를 읽는 소리로 받침을 가린다 (엠 → 받침, 포 → 없음).
        static func particle(_ word: String, _ withFinal: String, _ withoutFinal: String) -> String {
            guard let last = word.lowercased().unicodeScalars.last else { return withoutFinal }
            let hasFinal: Bool
            if (0xAC00...0xD7A3).contains(last.value) {
                hasFinal = (last.value - 0xAC00) % 28 != 0
            } else {
                hasFinal = "lmnr013678".unicodeScalars.contains(last)
            }
            return hasFinal ? withFinal : withoutFinal
        }

        var status: HTTPResponseStatus {
            if case .tooLarge = self { return .payloadTooLarge }
            return .badRequest
        }
    }

    /// 형식, 크기, 길이를 본다.
    static func check(_ data: Data) throws(Rejection) -> VideoInspection.Format {
        guard data.count <= maximumSize else { throw .tooLarge }
        guard let format = VideoInspection.format(of: data) else { throw .notVideo }
        guard let duration = VideoInspection.duration(of: data) else { throw .unreadableDuration }
        // 녹화 프로그램이 끝을 몇 프레임 넘겨 적기도 한다. 60초짜리가 60.02초로 거절되면
        // 사람은 이유를 알 수 없다. 반올림해서 본다.
        guard duration.rounded() <= maximumDuration else { throw .tooLong(seconds: duration) }
        return format
    }
}

/// 동영상을 받고, 내주고, 지운다.
///
/// 스크린샷처럼 두 길이 있다. 콘솔 폼은 파일 하나를 받고 화면으로 돌아가고, API 는 본문
/// 그 자체를 받고 앱을 돌려준다. **새로 올리면 앞의 것과 바뀐다.** 하나뿐인 자리라 지우고
/// 올리게 하면 한 번 더 누를 뿐 얻는 것이 없다.
struct AppVideoController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        // 스크린샷과 같은 까닭으로 내주는 쪽도 로그인을 건다 (ADR-0071).
        let api = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apiRoot.pathComponents)
        api.get("apps", ":appID", "video", use: serve)
        api.on(
            .PUT,
            "apps", ":appID", "video",
            body: .collect(maxSize: .init(value: AppVideos.maximumSize)),
            use: uploadOne
        )
        api.delete("apps", ":appID", "video", use: deleteOne)

        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("apps", ":appID", "video")
        pages.on(
            .POST,
            // multipart 경계와 다른 칸이 붙으므로 조금 넉넉히 받는다.
            body: .collect(maxSize: .init(value: AppVideos.maximumSize + 256 * 1024)),
            use: upload
        )
        pages.post("delete", use: delete)
    }

    struct UploadForm: Content {
        var video: File?
    }

    // MARK: - 받기

    @Sendable
    func upload(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)
        let appID = try app.requireID()

        guard let file = try request.content.decode(UploadForm.self).video,
              file.data.readableBytes > 0
        else {
            return try await reject("올릴 동영상을 고르세요.", status: .badRequest, app: app, user: user, on: request)
        }
        let data = Data(buffer: file.data)
        let format: VideoInspection.Format
        do {
            format = try AppVideos.check(data)
        } catch {
            return try await reject(error.reason(name: file.filename), status: error.status, app: app, user: user, on: request)
        }
        try await Self.store(data, format: format, for: app, by: user, on: request)
        return request.redirect(to: "/apps/\(appID.uuidString)/edit#video")
    }

    /// 본문 그 자체를 받고 앱을 돌려준다. 앱 아이콘·스크린샷 API 와 같은 모양이다.
    @Sendable
    func uploadOne(request: Request) async throws -> AppDTO {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        guard let buffer = request.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "동영상이 비어 있습니다.")
        }
        let data = Data(buffer: buffer)
        let format: VideoInspection.Format
        do {
            format = try AppVideos.check(data)
        } catch {
            throw Abort(error.status, reason: error.reason(name: nil))
        }
        try await Self.store(data, format: format, for: app, by: user, on: request)
        return try await Self.dto(of: app, on: request)
    }

    /// 스토리지에 넣고 앱의 키를 갈아끼운 뒤 앞의 오브젝트를 지운다.
    private static func store(
        _ data: Data,
        format: VideoInspection.Format,
        for app: App,
        by user: User,
        on request: Request
    ) async throws {
        let appID = try app.requireID()
        let key = request.artifactStorage.newKey(AppVideos.key(appID: appID, id: UUID(), format: format))
        try await request.artifactStorage.put(data, to: key, contentType: format.contentType)

        // **앞의 키를 읽어 두었다가 바꾸지 않는다.** 둘이 동시에 올리면 둘 다 같은 옛 키를
        // 읽고, 먼저 저장한 쪽의 오브젝트는 아무도 가리키지 않은 채 남는다. 행을 잠그고
        // 바꾸면서 바로 그 순간의 옛 키를 돌려받는다.
        let previous: String?
        do {
            previous = try await swap(to: key, in: appID, on: request.db)
        } catch {
            try? await request.artifactStorage.delete(key: key)
            throw error
        }
        if let previous {
            do {
                try await request.artifactStorage.delete(key: previous)
            } catch {
                request.logger.warning("앞의 앱 동영상 오브젝트를 지우지 못했습니다 [키: \(previous), 오류: \(error)]")
            }
        }
        request.logger.notice(
            "앱 동영상을 받았습니다 [\(app.bundleID), \(data.count) 바이트, 올린 사람: \(user.email)]"
        )
    }

    /// 키를 바꾸고 바로 앞의 키를 돌려준다. 없었으면 nil.
    private static func swap(to key: String?, in appID: UUID, on database: any Database) async throws -> String? {
        let row = try await sql(database).raw(
            """
            UPDATE apps AS a SET video_key = \(bind: key)
            FROM (SELECT id, video_key FROM apps WHERE id = \(bind: appID) FOR UPDATE) AS old
            WHERE a.id = old.id
            RETURNING old.video_key AS previous
            """
        ).first()
        return try row?.decodeNil(column: "previous") == false
            ? try row?.decode(column: "previous", as: String.self)
            : nil
    }

    private static func dto(of app: App, on request: Request) async throws -> AppDTO {
        let appID = try app.requireID()
        let fresh = try await App.find(appID, on: request.db) ?? app
        let latest = try await App.latestReleasedVersion(ofApp: appID, on: request.db)
        return try fresh.toDTO(
            latestReleased: latest, baseURL: request.application.alleyConfig.publicBaseURL
        )
    }

    /// 고치는 화면에 머문 채 무엇이 틀렸는지 말한다.
    private func reject(
        _ reason: String, status: HTTPResponseStatus, app: App, user: User, on request: Request
    ) async throws -> Response {
        let fresh = try await App.find(app.requireID(), on: request.db) ?? app
        let view = try await AppPagesController.renderEdit(
            app: fresh, user: user, values: nil, videoError: reason, on: request
        )
        return htmlResponse(view, status: status)
    }

    // MARK: - 지우기

    @Sendable
    func delete(request: Request) async throws -> Response {
        let app = try await Self.remove(on: request)
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)/edit#video")
    }

    @Sendable
    func deleteOne(request: Request) async throws -> AppDTO {
        try await Self.dto(of: try await Self.remove(on: request), on: request)
    }

    private static func remove(on request: Request) async throws -> App {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)
        guard app.videoKey != nil else {
            throw Abort(.notFound, reason: "동영상이 없습니다.")
        }
        // 행을 먼저 비운다. 오브젝트를 먼저 지우고 행 저장이 실패하면 화면에 깨진 영상이
        // 남는다. 반대로 실패하면 아무도 가리키지 않는 오브젝트만 남는다.
        if let previous = try await swap(to: nil, in: try app.requireID(), on: request.db) {
            do {
                try await request.artifactStorage.delete(key: previous)
            } catch {
                request.logger.warning("앱 동영상 오브젝트를 지우지 못했습니다 [키: \(previous), 오류: \(error)]")
            }
        }
        request.logger.notice("앱 동영상을 지웠습니다 [\(app.bundleID), 지운 사람: \(user.email)]")
        return app
    }

    // MARK: - 내주기

    /// 로그인과 볼 권한을 확인한 뒤 잠깐 쓰는 스토리지 주소로 넘긴다.
    ///
    /// **스크린샷처럼 서버가 받아 넘기지 않는다.** 수십 MB 를 매번 서버 메모리에 올려야
    /// 하고, 동영상은 앞뒤로 넘길 때 구간(Range)을 따로 청한다. Safari 는 구간을 받지
    /// 않는 서버의 영상은 아예 틀지 않는다. 스토리지는 둘 다 한다.
    @Sendable
    func serve(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        // 출시 전인 앱은 손댈 수 있는 사람에게만 보인다 (ADR-0051).
        if try await App.latestReleasedVersion(ofApp: app.requireID(), on: request.db) == nil {
            guard try await AppVisibility.of(user, on: request.db).canTouch(app) else {
                throw Abort(.notFound, reason: "동영상을 찾을 수 없습니다.")
            }
        }
        guard let key = app.videoKey else {
            throw Abort(.notFound, reason: "동영상을 찾을 수 없습니다.")
        }
        let presigned = try await request.artifactStorage.downloadURL(key: key)
        let response = request.redirect(to: presigned.url)
        // 넘겨주는 주소는 곧 만료된다. 넘김 자체를 기억해 두면 만료된 주소로 간다.
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    private static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw MigrationError.needsSQLDatabase }
        return sql
    }
}
