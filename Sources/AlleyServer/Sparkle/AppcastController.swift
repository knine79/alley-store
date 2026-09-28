import AlleyShared
import Fluent
import Foundation
import Vapor

/// Sparkle 피드와 그 토큰.
///
/// 이 경로만 로그인 없이 열린다. Sparkle 은 우리가 만든 클라이언트가 아니라서
/// 세션도 헤더도 들고 있지 않기 때문이다(ADR-0006). 대신 앱별 피드 토큰을 주소에
/// 실어 받는다. 그 토큰으로 할 수 있는 것은 **그 앱의 출시본을 보고 받는 것**
/// 뿐이다. 자세한 대가는 ADR-0017 에 있다.
///
/// 토큰은 **경로 세그먼트**로 받는다. 질의 항목으로 받던 것을 옮겼다. 질의 항목만
/// 따로 기록하거나 그것만 훑는 도구가 흔해서 그렇다. **전체 URL 을 통째로 적는 로거
/// 앞에서는 아무것도 나아지지 않는다.** 무엇이 나아지고 무엇이 그대로인지는
/// ADR-0025 에 적었다.
///
/// 옛 질의 형식도 당분간 받는다. 이미 배포된 앱의 `Info.plist` 에 그 주소가 박혀
/// 있어서 여기서 끊으면 그 앱들이 조용히 업데이트를 멈춘다.
public struct AppcastController: RouteCollection, Sendable {
    /// 피드에 싣는 항목 수.
    ///
    /// Sparkle 은 가장 높은 버전 하나만 쓰지만, 사람이 열어볼 때 최근 몇 개가 보이는
    /// 편이 낫다. 전부 싣지 않는 이유는 오래된 아티팩트의 presigned URL 을 만드는
    /// 비용이 항목 수만큼 들기 때문이다.
    static let itemLimit = 10

    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        // 인증 미들웨어를 걸지 않는다. 주소에 실린 토큰을 여기서 직접 확인한다.
        let open = routes.grouped(APIPath.apps.pathComponents)
        open.get(":appID", "feed", ":token", "appcast.xml", use: feed)
        // 폐기 예정. 이미 배포된 앱이 들고 있는 형식이라 아직 받는다.
        open.get(":appID", "appcast.xml", use: legacyFeed)

        // 로그인한 사람이 앱 단위로 부르는 것들. 인증을 두 번 적지 않는다. 한쪽에만
        // 미들웨어를 더하는 날 그 경로만 조용히 헐거워진다.
        let ofApp = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.apps.pathComponents)

        let managed = ofApp.grouped(":appID", "feed-tokens")
        managed.get(use: list)
        managed.post(use: issue)
        managed.delete(":tokenID", use: revoke)

        // 앱에 넣을 공개키와 지금 쓸 수 있는 상태인지 (ADR-0060). 화면이 말하는
        // 것과 같은 것을 같은 코드로 내준다.
        ofApp.get(":appID", "sparkle", use: feedStatus)
    }

    /// 이 앱에서 Sparkle 을 쓸 수 있는 상태인가.
    ///
    /// **앱을 만드는 사람이 `SUPublicEDKey` 를 여기서 가져간다.** 개인키를 가진
    /// 사람을 찾아갈 필요가 없다 (ADR-0057). 막혀 있으면 무엇이 막고 있는지도
    /// 같은 줄로 온다.
    @Sendable
    func feedStatus(request: Request) async throws -> SparkleFeedDTO {
        let app = try await request.findApp()
        // **올릴 수 있는 사람이면 본다.** 피드 토큰을 발급하는 것과 다른 기준이다.
        // 여기서 나가는 공개키는 워커 전체가 공유하는 공개 정보이고, 그것을 개인키
        // 가진 사람 찾아가지 않고 얻게 하는 것이 ADR-0057 의 요점이다. 버전을 올리는
        // 사람이 자기 앱의 `SUPublicEDKey` 를 못 보는 것은 앞뒤가 안 맞는다.
        _ = try await request.requireUploadRights(to: app)

        // 서로 기다릴 이유가 없다. 에이전트가 짧은 간격으로 부르는 자리다.
        async let readinessTask = SparkleReadinessRow.of(app: app, on: request.db)
        async let issuedTask = FeedToken.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .filter(\.$revokedAt == nil)
            .count()
        let (readiness, issued) = try await (readinessTask, issuedTask)

        return SparkleFeedDTO(
            publicKey: readiness.publicKey,
            canIssue: readiness.canIssue,
            readiness: readiness.state,
            note: readiness.blocker,
            issuedFeedCount: issued
        )
    }

    // MARK: - 피드

    @Sendable
    func feed(request: Request) async throws -> Response {
        let token = request.parameters.get("token").flatMap { $0.isEmpty ? nil : $0 }
        return try await feed(request: request, token: token, isLegacyURL: false)
    }

    /// 토큰을 질의 항목으로 받던 옛 주소.
    ///
    /// 응답에 `Deprecation` 을 붙이고 로그를 남긴다. 어느 앱이 아직 옛 주소를 들고
    /// 있는지 알아야 언젠가 이 경로를 지울 수 있는데, 그 답은 로그에만 있다.
    /// 언제 지울지는 아직 정하지 않았다 (ADR-0025).
    @Sendable
    func legacyFeed(request: Request) async throws -> Response {
        let token = request.query[String.self, at: APIPath.feedTokenQueryItem]
            .flatMap { $0.isEmpty ? nil : $0 }
        let response = try await feed(request: request, token: token, isLegacyURL: true)
        response.headers.replaceOrAdd(name: "Deprecation", value: "true")
        return response
    }

    private func feed(
        request: Request,
        token: String?,
        isLegacyURL: Bool
    ) async throws -> Response {
        let (app, feedToken) = try await authorizedApp(on: request, token: token)
        let appID = try app.requireID()

        if isLegacyURL {
            request.logger.notice(
                "폐기 예정인 질의 형식 피드 주소 사용 [앱: \(app.bundleID), 토큰: \(feedToken.name)]"
            )
        }

        let versions = try await Version.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$state == .released)
            .with(\.$artifacts)
            .sort(\.$buildNumber, .descending)
            .range(..<Self.itemLimit)
            .all()

        var items: [Appcast.Item] = []
        for version in versions {
            guard let artifact = version.bestArtifact else { continue }
            let presigned = try await request.artifactStorage.downloadURL(key: artifact.storageKey)

            items.append(
                Appcast.Item(
                    shortVersion: version.shortVersion,
                    buildNumber: version.buildNumber,
                    releaseNotes: version.releaseNotes,
                    minimumSystemVersion: version.minimumOSVersion,
                    publishedAt: version.releasedAt ?? version.createdAt ?? Date(),
                    downloadURL: presigned.url,
                    fileSize: artifact.fileSize,
                    edSignature: artifact.edSignature
                )
            )
        }

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "application", subType: "rss+xml")
        // 피드에 만료 있는 URL 이 들어 있다. 중간에서 캐시하면 만료된 주소가 돌아다닌다.
        response.headers.cacheControl = .init(noStore: true)
        response.body = .init(string: Appcast.xml(appName: app.name, items: items))
        return response
    }

    /// 주소에 실린 토큰으로 앱을 찾는다.
    ///
    /// 토큰이 틀리면 앱이 있는지조차 알려주지 않고 404 를 준다. 앱 ID 만 바꿔가며
    /// 어떤 앱이 있는지 훑는 것을 막는다.
    private func authorizedApp(
        on request: Request,
        token value: String?
    ) async throws -> (App, FeedToken) {
        guard let appID = request.parameters.get("appID", as: UUID.self),
              let value
        else {
            throw Abort(.notFound, reason: "피드를 찾을 수 없습니다.")
        }

        guard let token = try await FeedToken.query(on: request.db)
            .filter(\.$tokenHash == FeedToken.hash(token: value))
            .filter(\.$app.$id == appID)
            .with(\.$app)
            .first(),
            token.isActive
        else {
            request.logger.warning("잘못된 피드 토큰으로 접근 [앱: \(appID)]")
            throw Abort(.notFound, reason: "피드를 찾을 수 없습니다.")
        }

        token.lastUsedAt = Date()
        try await token.save(on: request.db)
        return (token.app, token)
    }

    // MARK: - 토큰

    @Sendable
    func list(request: Request) async throws -> [FeedTokenDTO] {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        return try await FeedToken.query(on: request.db)
            .filter(\.$app.$id == app.requireID())
            .sort(\.$name)
            .all()
            .map { try $0.toDTO() }
    }

    @Sendable
    func issue(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        let payload = try request.content.decode(CreateFeedTokenRequest.self)
        let created = try await FeedTokenIssuing.issue(
            named: payload.name,
            for: app,
            by: user,
            baseURL: request.application.alleyConfig.publicBaseURL,
            on: request.db,
            logger: request.logger
        )

        let response = Response(status: .created)
        try response.content.encode(created)
        return response
    }

    @Sendable
    func revoke(request: Request) async throws -> HTTPStatus {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)

        guard let tokenID = request.parameters.get("tokenID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "토큰 ID 형식이 올바르지 않습니다.")
        }
        try await FeedTokenIssuing.revoke(
            tokenID,
            ofApp: app,
            by: user,
            on: request.db,
            logger: request.logger
        )
        return .noContent
    }
}

/// 피드 토큰 발급과 폐기의 규칙.
enum FeedTokenIssuing {
    static func issue(
        named name: String,
        for app: App,
        by user: User,
        baseURL: String,
        on database: any Database,
        logger: Logger
    ) async throws -> CreatedFeedToken {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "토큰 이름은 비울 수 없습니다.")
        }

        // 배포 토큰과 같은 이유로 한 앱 안에서 이름이 겹치지 않게 한다
        // (`DeployTokenIssuing.issue` 참고).
        let sameName = try await FeedToken.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .filter(\.$name == trimmed)
            .all()
        guard !sameName.contains(where: \.isActive) else {
            throw Abort(.conflict, reason: "'\(trimmed)' 은 이미 쓸 수 있는 피드입니다. 새로 발급하려면 그것부터 폐기하세요.")
        }

        let value = FeedToken.generateToken()
        let token = FeedToken(
            appID: try app.requireID(),
            name: trimmed,
            tokenHash: FeedToken.hash(token: value),
            createdByID: try user.requireID()
        )
        try await token.save(on: database)

        logger.notice("피드 토큰 발급 [앱: \(app.bundleID), 이름: \(trimmed), 발급: \(user.email)]")
        return CreatedFeedToken(
            token: try token.toDTO(),
            value: value,
            feedURL: feedURL(baseURL: baseURL, appID: try app.requireID(), token: value)
        )
    }

    /// 앱의 `SUFeedURL` 에 그대로 넣을 주소.
    ///
    /// 토큰을 사람이 손으로 붙이게 하면 실수가 난다. 완성된 주소를 준다.
    /// **새 형식으로만 낸다.** 옛 질의 형식은 이미 나가 있는 주소를 받아주기만 한다.
    static func feedURL(baseURL: String, appID: UUID, token: String) -> String {
        var base = baseURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return "\(base)\(APIPath.appcast(ofApp: appID, token: token))"
    }

    @discardableResult
    static func revoke(
        _ tokenID: UUID,
        ofApp app: App,
        by user: User,
        on database: any Database,
        logger: Logger
    ) async throws -> FeedToken {
        guard let token = try await FeedToken.query(on: database)
            .filter(\.$id == tokenID)
            .filter(\.$app.$id == app.requireID())
            .first()
        else {
            throw Abort(.notFound, reason: "토큰을 찾을 수 없습니다.")
        }
        guard token.isActive else {
            throw Abort(.conflict, reason: "이미 폐기된 토큰입니다.")
        }

        token.revokedAt = Date()
        try await token.save(on: database)

        logger.notice("피드 토큰 폐기 [앱: \(app.bundleID), 이름: \(token.name), 폐기: \(user.email)]")
        return token
    }
}

extension SparkleFeedDTO: Content {}
extension FeedTokenDTO: Content {}
extension CreateFeedTokenRequest: Content {}
extension CreatedFeedToken: Content {}
