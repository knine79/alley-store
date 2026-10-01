import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 스크린샷의 규칙 (이슈 #40).
///
/// 앱 이름과 설명만으로는 무엇을 하는 앱인지 감이 오지 않을 때가 있다. 받기 전에 화면을
/// 볼 수 있게 한다. **버전이 아니라 앱에 묶는다.** 사내 앱은 버전마다 바꿀 만큼 화면이
/// 달라지지 않고, 버전마다 다시 올리게 하면 아무도 올리지 않는다.
enum AppScreenshots {
    /// 앱 하나에 둘 수 있는 수.
    static let maximumCount = 5
    /// 한 장의 크기. 레티나 전체 화면 PNG 도 보통 이 안에 든다.
    static let maximumSize = 5 * 1024 * 1024

    enum Format: String {
        case png
        case jpeg

        var contentType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpg"
            }
        }
    }

    /// 내용으로 형식을 가린다. 파일 이름이나 브라우저가 붙인 형식은 믿지 않는다.
    static func format(of data: Data) -> Format? {
        if data.starts(with: PNGInspection.signature) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        return nil
    }

    static func key(appID: UUID, id: UUID, format: Format) -> String {
        "apps/\(appID.uuidString)/screenshots/\(id.uuidString.lowercased()).\(format.fileExtension)"
    }

    /// 키에서 주소에 쓰는 ID 를 꺼낸다. 스토리지 접두어가 붙어 있어도 된다.
    static func id(fromKey key: String) -> UUID? {
        guard let file = key.split(separator: "/").last,
              let stem = file.split(separator: ".").first
        else { return nil }
        return UUID(uuidString: String(stem))
    }

    /// 확장자로 형식을 되찾는다. 내줄 때 쓴다.
    static func format(ofKey key: String) -> Format {
        key.hasSuffix(".jpg") ? .jpeg : .png
    }
}

/// 스크린샷을 받고, 내주고, 지운다.
///
/// 받기와 지우기는 콘솔 폼이 부른다. 앱 상세에서 고르고 올리는 것으로 충분하고,
/// 에이전트가 스크린샷까지 올릴 일은 아직 없다.
struct AppScreenshotController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        // **내주는 쪽도 로그인을 건다.** 아이콘과 다르다. 사내 앱 화면에는 사내 데이터가
        // 찍힐 수 있다. 스토어 앱은 토큰을 붙여 받고, 콘솔은 쿠키로 받는다.
        routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apiRoot.pathComponents)
            .get("apps", ":appID", "screenshots", ":screenshotID", use: serve)

        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("apps", ":appID", "screenshots")
        pages.on(
            .POST,
            // multipart 경계와 다른 칸이 붙으므로 한 장 크기보다 조금 넉넉히 받는다.
            body: .collect(maxSize: .init(value: AppScreenshots.maximumSize + 64 * 1024)),
            use: upload
        )
        pages.post(":screenshotID", "delete", use: delete)
    }

    struct UploadForm: Content {
        var image: File?
    }

    // MARK: - 받기

    @Sendable
    func upload(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        let form = try request.content.decode(UploadForm.self)
        guard let file = form.image, file.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "올릴 이미지를 고르세요.")
        }
        guard file.data.readableBytes <= AppScreenshots.maximumSize else {
            throw Abort(.payloadTooLarge, reason: "스크린샷은 한 장에 5MB 까지입니다.")
        }
        let data = Data(buffer: file.data)
        guard let format = AppScreenshots.format(of: data) else {
            throw Abort(.badRequest, reason: "PNG 나 JPEG 만 올릴 수 있습니다.")
        }
        guard app.screenshotKeys.count < AppScreenshots.maximumCount else {
            throw Abort(
                .badRequest,
                reason: "스크린샷은 \(AppScreenshots.maximumCount)장까지입니다. 하나를 지우고 올리세요."
            )
        }

        let appID = try app.requireID()
        let key = request.artifactStorage.newKey(
            AppScreenshots.key(appID: appID, id: UUID(), format: format)
        )
        try await request.artifactStorage.put(data, to: key, contentType: format.contentType)
        app.screenshotKeys.append(key)
        do {
            try await app.save(on: request.db)
        } catch {
            // 행에 적지 못한 오브젝트는 아무도 가리키지 않는다. 남기지 않는다.
            try? await request.artifactStorage.delete(key: key)
            throw error
        }

        request.logger.notice("앱 스크린샷을 받았습니다 [\(app.bundleID), 올린 사람: \(user.email)]")
        return request.redirect(to: "/apps/\(appID.uuidString)#screenshots")
    }

    // MARK: - 지우기

    @Sendable
    func delete(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)
        let key = try Self.key(in: app, on: request)

        // 행을 먼저 고친다. 오브젝트를 먼저 지우고 행 저장이 실패하면 화면에 깨진
        // 그림이 남는다. 반대로 실패하면 아무도 가리키지 않는 오브젝트만 남는다.
        app.screenshotKeys.removeAll { $0 == key }
        try await app.save(on: request.db)
        do {
            try await request.artifactStorage.delete(key: key)
        } catch {
            request.logger.warning("앱 스크린샷 오브젝트를 지우지 못했습니다 [키: \(key), 오류: \(error)]")
        }
        return request.redirect(to: "/apps/\(try app.requireID().uuidString)#screenshots")
    }

    // MARK: - 내주기

    @Sendable
    func serve(request: Request) async throws -> Response {
        let app = try await request.findApp()
        let key = try Self.key(in: app, on: request)

        // 키에 UUID 가 들어 있어 내용이 바뀌면 주소도 바뀐다. 키가 그대로 ETag 다.
        let etag = "\"\(key)\""
        if request.headers.first(name: .ifNoneMatch) == etag {
            let response = Response(status: .notModified)
            response.headers.replaceOrAdd(name: .eTag, value: etag)
            return response
        }

        // 아이콘과 달리 `storedImages` 에 두지 않는다. 한 장이 수 MB 라 몇 장만 들어가도
        // 아이콘과 브랜딩 이미지가 밀려난다. 앱 상세를 열 때만 부르는 것이라 매번
        // 스토리지를 다녀와도 된다.
        let data = try await request.artifactStorage.get(key: key, limit: AppScreenshots.maximumSize)
        let format = AppScreenshots.format(ofKey: key)
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: format.contentType)
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        // 로그인한 사람에게만 내주는 것이라 공유 캐시에 두지 않는다.
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=300")
        response.body = .init(data: data)
        return response
    }

    /// 주소의 ID 가 가리키는 이 앱의 키. 없으면 404.
    private static func key(in app: App, on request: Request) throws -> String {
        guard let id = request.parameters.get("screenshotID", as: UUID.self),
              let key = app.screenshotKeys.first(where: { AppScreenshots.id(fromKey: $0) == id })
        else {
            throw Abort(.notFound, reason: "스크린샷을 찾을 수 없습니다.")
        }
        return key
    }
}
