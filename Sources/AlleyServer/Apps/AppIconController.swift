import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 아이콘을 받고 내준다.
///
/// **사람이 따로 올리지 않는다.** 아이콘은 이미 번들 안에 있고, 그것을 다시 찾아
/// 올리게 하는 것은 할 일을 옮긴 것뿐이다. 옮긴 쪽은 잊는다. 브라우저가 올릴 zip 을
/// 열어 `.icns` 에서 PNG 를 꺼내 함께 보낸다 (`Public/bundle-info.js`).
/// 번들의 값을 읽어 입력칸을 채우는 것과 같은 자리이고 같은 이유다 (ADR-0030).
///
/// 저장과 서빙은 브랜딩 이미지와 같은 길을 쓴다 (ADR-0045). 다른 점은 종류가 아니라
/// 앱마다 하나라는 것뿐이다.
struct AppIconController: RouteCollection, Sendable {
    /// 받아줄 최대 크기. 1024 PNG 는 보통 수백 KB 다.
    static let maximumSize = 8 * 1024 * 1024

    func boot(routes: any RoutesBuilder) throws {
        // 내주는 쪽은 로그인을 걸지 않는다. 스토어 앱이 목록을 그릴 때 줄마다
        // 부르는 주소라, 여기에 인증을 걸면 그림 하나에 토큰이 하나씩 붙는다.
        // 그림의 내용은 앱 아이콘이고 감출 것이 아니다.
        routes.get("apps", ":appID", "icon.png", use: serve)

        let authenticated = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apiRoot.pathComponents)

        authenticated.on(
            .POST,
            "apps", ":appID", "icon",
            body: .collect(maxSize: .init(value: Self.maximumSize)),
            use: upload
        )
    }

    // MARK: - 받기

    @Sendable
    func upload(request: Request) async throws -> AppDTO {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        guard let buffer = request.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "이미지가 비어 있습니다.")
        }
        let data = Data(buffer: buffer)

        // 번들에서 꺼낸 그림이라 크기가 제각각이다. 정사각형만 요구하고 하한은
        // 낮게 둔다. 여기서 막으면 아이콘이 없는 채로 남는데, 작은 아이콘이라도
        // 있는 편이 글자만 있는 것보다 낫다.
        let size = try PNGInspection.validate(data, rule: .atLeast(32), label: "앱 아이콘")

        let appID = try app.requireID()
        let key = request.artifactStorage.newKey(
            "apps/\(appID.uuidString)/icon-\(UUID().uuidString.lowercased()).png"
        )
        try await request.artifactStorage.put(data, to: key, contentType: "image/png")

        let previousKey = app.iconStorageKey
        app.iconStorageKey = key
        // 화면과 스토어 앱이 보는 것은 이 값이다. 우리가 내주는 주소를 적어두면
        // `AppDTO` 를 그대로 쓰는 쪽(스토어 앱 목록)이 아무것도 몰라도 된다.
        app.iconURL = "/apps/\(appID.uuidString)/icon.png?v=\(Int(Date().timeIntervalSince1970))"
        try await app.save(on: request.db)

        if let previousKey, previousKey != key {
            do {
                try await request.artifactStorage.delete(key: previousKey)
            } catch {
                request.logger.warning("옛 앱 아이콘을 지우지 못했습니다 [키: \(previousKey), 오류: \(error)]")
            }
        }

        request.logger.notice(
            "앱 아이콘을 받았습니다 [\(app.bundleID), \(size.width)×\(size.height), 올린 사람: \(user.email)]"
        )
        try await app.$versions.load(on: request.db)
        return try app.toDTO()
    }

    // MARK: - 내주기

    @Sendable
    func serve(request: Request) async throws -> Response {
        let app = try await request.findApp()
        guard let key = app.iconStorageKey else {
            throw Abort(.notFound)
        }

        // 키에 UUID 가 들어 있어 내용이 바뀌면 키도 바뀐다. 키가 그대로 ETag 다.
        let etag = "\"\(key)\""
        if request.headers.first(name: .ifNoneMatch) == etag {
            let response = Response(status: .notModified)
            response.headers.replaceOrAdd(name: .eTag, value: etag)
            return response
        }

        let data = try await request.application.brandingCache.data(forKey: key) {
            try await request.application.artifactStorage.get(key: key, limit: Self.maximumSize)
        }

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "image", subType: "png")
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=60")
        response.body = .init(data: data)
        return response
    }
}
