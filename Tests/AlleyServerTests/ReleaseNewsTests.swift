import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

@Suite("출시 소식 글")
struct ReleaseNewsMessageTests {
    private func compose(
        first: Bool,
        version: String = "1.0",
        summary: String? = "메뉴 막대에서 클립보드 기록을 관리합니다",
        notes: String? = "- 첫 출시"
    ) -> ReleaseNews.Message {
        ReleaseNews.compose(
            appName: "클립보드 매니저",
            summary: summary,
            shortVersion: version,
            releaseNotes: notes,
            isFirstRelease: first,
            storeName: "Alley Store",
            link: "https://store.example.com/a/abc"
        )
    }

    @Test("새 앱은 출시되었다고 알린다")
    func firstRelease() {
        let message = compose(first: true)
        #expect(message.text == "🎉클립보드 매니저 1.0 이 Alley Store에 출시되었습니다.")
        #expect(message.blocks == [
            .context("Alley Store 출시 소식"),
            .section("*🎉클립보드 매니저 1.0 이 Alley Store에 출시되었습니다.*\n메뉴 막대에서 클립보드 기록을 관리합니다"),
            .section("> - 첫 출시"),
            .section("<https://store.example.com/a/abc|Alley Store에서 보기>"),
        ])
    }

    @Test("업데이트는 업데이트되었다고 알린다")
    func update() {
        #expect(compose(first: false, version: "1.2").text == "✨클립보드 매니저 1.2 로 업데이트되었습니다.")
        // 영(0) 은 받침이 있다.
        #expect(compose(first: false, version: "2.0").text == "✨클립보드 매니저 2.0 으로 업데이트되었습니다.")
    }

    @Test("소개와 릴리즈 노트가 없으면 그 줄을 뺀다")
    func withoutOptionalParts() {
        let message = compose(first: true, summary: nil, notes: "  ")
        #expect(message.blocks.count == 3)
        #expect(message.blocks[1] == .section("*🎉클립보드 매니저 1.0 이 Alley Store에 출시되었습니다.*"))
    }

    /// Slack 은 3000자가 넘는 블록을 통째로 거절한다. 소개 길이를 막는 곳이 없다.
    @Test("소개는 300자까지만 싣는다")
    func summaryCut() {
        let message = compose(first: true, summary: String(repeating: "가", count: 400), notes: nil)
        guard case .section(let headline) = message.blocks[1] else {
            Issue.record("두 번째 블록이 본문이 아닙니다")
            return
        }
        #expect(headline.hasSuffix(String(repeating: "가", count: 300) + "…"))
    }

    @Test("릴리즈 노트는 다섯 줄까지만 싣는다")
    func notesCutAtFiveLines() {
        let notes = (1...7).map { "- 고친 것 \($0)" }.joined(separator: "\n")
        #expect(ReleaseNews.excerpt(of: notes) == (1...5).map { "- 고친 것 \($0)" }.joined(separator: "\n") + "…")
    }

    @Test("릴리즈 노트는 300자까지만 싣는다")
    func notesCutAtCharacterLimit() throws {
        let excerpt = try #require(ReleaseNews.excerpt(of: String(repeating: "가", count: 400)))
        #expect(excerpt.count == ReleaseNews.noteCharacterLimit + 1)
        #expect(excerpt.hasSuffix("…"))
    }

    @Test("짧은 릴리즈 노트는 그대로 싣는다")
    func shortNotesUntouched() {
        #expect(ReleaseNews.excerpt(of: "- 하나\n\n- 둘") == "- 하나\n- 둘")
    }

    /// 앱 이름의 `<` 가 링크로 읽히면 글이 깨진다.
    @Test("Slack 이 문법으로 읽는 글자를 바꾼다")
    func escapesMarkup() {
        #expect(ReleaseNews.escaped("A<B> & C") == "A&lt;B&gt; &amp; C")
    }
}

@Suite("받침에 따른 조사")
struct KoreanParticleTests {
    @Test("숫자는 읽는 소리로 가른다", arguments: [
        ("1.0", "이", "으로"), ("1.1", "이", "로"), ("1.2", "가", "로"),
        ("1.3", "이", "으로"), ("1.5", "가", "로"), ("1.6", "이", "으로"),
    ])
    func digits(word: String, subject: String, direction: String) {
        #expect(KoreanParticle.subject(after: word) == subject)
        #expect(KoreanParticle.direction(after: word) == direction)
    }

    @Test("한글은 받침으로 가른다")
    func hangul() {
        #expect(KoreanParticle.subject(after: "베타") == "가")
        #expect(KoreanParticle.subject(after: "정식") == "이")
        #expect(KoreanParticle.direction(after: "정식") == "으로")
        #expect(KoreanParticle.direction(after: "알파벌") == "로")
    }

    @Test("읽는 법을 모르면 둘을 함께 적는다")
    func unknown() {
        #expect(KoreanParticle.subject(after: "1.0b") == "이(가)")
        #expect(KoreanParticle.direction(after: "1.0b") == "(으)로")
    }
}

@Suite("출시 소식 보내기")
struct ReleaseNewsDeliveryTests {
    private let botEnv = ["SLACK_BOT_TOKEN": "xoxb-test"]

    private struct Fixture {
        var owner: User
        var token: String
        var appID: UUID
        var versionID: UUID
    }

    private func seed(
        on app: Application,
        stub: SlackAPIStub,
        channel: Bool = true,
        state: VersionState = .ready
    ) async throws -> Fixture {
        app.clients.use { _ in stub }
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.clip", name: "클립보드 매니저", owner: owner)
        record.summary = "메뉴 막대에서 클립보드 기록을 관리합니다"
        try await record.save(on: app.db)
        let appID = try record.requireID()
        if channel {
            try await ReleaseChannel(
                appID: appID, slackChannelID: "C0123456789", name: "team-clip",
                createdByID: try owner.requireID()
            ).save(on: app.db)
        }
        let version = try await app.seedVersion(appID: appID, short: "1.0", build: 1, state: state, by: owner)
        return Fixture(owner: owner, token: token, appID: appID, versionID: try version.requireID())
    }

    private func releaseOnWeb(
        _ fixture: Fixture, announce: Bool, on app: Application
    ) async throws {
        try await app.testing().test(
            .POST,
            "/apps/\(fixture.appID.uuidString)/versions/\(fixture.versionID.uuidString)/release",
            headers: .form(cookie: fixture.token),
            beforeRequest: { request in
                try request.content.encode(["announce": announce ? "1" : ""], as: .urlEncodedForm)
            }
        ) { #expect($0.status == .seeOther) }
    }

    @Test("알리기를 고르면 채널에 한 번 올린다")
    func announcesOnce() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)

            try await releaseOnWeb(fixture, announce: true, on: app)

            let posts = stub.posts
            #expect(posts.count == 1)
            #expect(posts.first?.contains("\"channel\":\"C0123456789\"") == true)
            #expect(posts.first?.contains("출시되었습니다") == true)

            let stored = try #require(try await Version.find(fixture.versionID, on: app.db))
            #expect(stored.state == .released)
            #expect(stored.announcedAt != nil)
            let channel = try #require(try await ReleaseChannel.query(on: app.db).first())
            #expect(channel.lastSentAt != nil)
            #expect(channel.lastError == nil)
        }
    }

    @Test("알리지 않기를 고르면 출시만 한다")
    func releasesWithoutAnnouncing() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)

            try await releaseOnWeb(fixture, announce: false, on: app)

            #expect(stub.posts.isEmpty)
            let stored = try #require(try await Version.find(fixture.versionID, on: app.db))
            #expect(stored.state == .released)
            #expect(stored.announcedAt == nil)
        }
    }

    /// 철회했다가 다시 출시하면 같은 버전이 채널에 두 번 올라간다.
    @Test("철회했다가 다시 출시해도 다시 알리지 않는다")
    func noRepeatAfterUnrelease() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)

            try await releaseOnWeb(fixture, announce: true, on: app)
            try await app.testing().test(
                .POST,
                "/apps/\(fixture.appID.uuidString)/versions/\(fixture.versionID.uuidString)/unrelease",
                headers: .form(cookie: fixture.token)
            ) { #expect($0.status == .seeOther) }
            try await releaseOnWeb(fixture, announce: true, on: app)

            #expect(stub.posts.count == 1)
        }
    }

    @Test("앞서 출시한 버전이 있으면 업데이트로 알린다")
    func updateAfterEarlierRelease() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)
            let earlier = try await app.seedVersion(
                appID: fixture.appID, short: "0.9", build: 0, state: .released, by: fixture.owner
            )
            earlier.releasedAt = Date()
            try await earlier.save(on: app.db)

            try await releaseOnWeb(fixture, announce: true, on: app)

            #expect(stub.posts.first?.contains("업데이트되었습니다") == true)
        }
    }

    @Test("봇이 없으면 출시만 한다")
    func noBotNoAnnouncement() async throws {
        try await withMigratedApp { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)

            try await releaseOnWeb(fixture, announce: true, on: app)

            #expect(stub.calls.isEmpty)
            let stored = try #require(try await Version.find(fixture.versionID, on: app.db))
            #expect(stored.state == .released)
            #expect(stored.announcedAt == nil)
        }
    }

    /// 알림 실패가 출시를 막으면, 출시한 사람은 출시가 안 된 줄 알고 다시 누른다.
    @Test("Slack 이 거절해도 출시는 되고 채널에 이유가 남는다")
    func failureDoesNotBlockRelease() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub(post: #"{"ok":false,"error":"not_in_channel"}"#)
            let fixture = try await seed(on: app, stub: stub)

            try await releaseOnWeb(fixture, announce: true, on: app)

            let stored = try #require(try await Version.find(fixture.versionID, on: app.db))
            #expect(stored.state == .released)
            let channel = try #require(try await ReleaseChannel.query(on: app.db).first())
            #expect(channel.lastError?.contains("not_in_channel") == true)
            // 한 곳에도 못 보냈으면 알린 것으로 치지 않는다. 고친 뒤 다시 보낼 수 있다.
            #expect(stored.announcedAt == nil)
        }
    }

    @Test("API 본문을 못 읽으면 출시하지 않고 말한다")
    func apiRejectsUnreadableBody() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)

            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token),
                beforeRequest: { try $0.content.encode(["announce": "yes"]) }
            ) { #expect($0.status == .badRequest) }

            let stored = try #require(try await Version.find(fixture.versionID, on: app.db))
            #expect(stored.state == .ready)
        }
    }

    @Test("API 는 announce 가 true 일 때만 알린다")
    func apiAnnouncesOnlyWhenAsked() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)

            // 예전 CLI 처럼 빈 객체를 보내면 알리지 않는다.
            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token),
                beforeRequest: { try $0.content.encode(ReleaseVersionRequest()) }
            ) { #expect($0.status == .ok) }
            #expect(stub.posts.isEmpty)

            try await app.testing().test(
                .DELETE, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token)
            ) { #expect($0.status == .ok) }

            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token),
                beforeRequest: { try $0.content.encode(ReleaseVersionRequest(announce: true)) }
            ) { #expect($0.status == .ok) }
            #expect(stub.posts.count == 1)
        }
    }

    /// 스토어 앱은 스스로 업데이트하고, 공유 링크도 상세가 아니라 설치 페이지로 간다.
    @Test("스토어 앱은 알리지 않는다")
    func storeAppIsNotAnnounced() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            settings.$app.id = fixture.appID
            try await settings.save(on: app.db)

            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token),
                beforeRequest: { try $0.content.encode(ReleaseVersionRequest(announce: true)) }
            ) { #expect($0.status == .ok) }

            #expect(stub.posts.isEmpty)
        }
    }

    /// 웹에만 있던 검사가 API 에도 걸린다. 출시가 한 곳을 지나게 됐다.
    @Test("API 도 번들 ID 가 확정되지 않은 앱은 출시하지 않는다")
    func apiRefusesPendingBundleID() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let fixture = try await seed(on: app, stub: stub)
            let record = try #require(try await App.find(fixture.appID, on: app.db))
            record.bundleIDPending = true
            try await record.save(on: app.db)

            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token)
            ) { #expect($0.status == .conflict) }
        }
    }
}

@Suite("출시 소식 채널 등록")
struct ReleaseChannelRegistrationTests {
    private let botEnv = ["SLACK_BOT_TOKEN": "xoxb-test"]

    private func seed(on app: Application, stub: SlackAPIStub) async throws -> (String, UUID) {
        app.clients.use { _ in stub }
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.clip", name: "클립보드 매니저", owner: owner)
        _ = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0", build: 1, state: .ready, by: owner
        )
        return (token, try record.requireID())
    }

    private func add(_ channel: String, token: String, appID: UUID, on app: Application) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.testing().test(
            .POST, "/apps/\(appID.uuidString)/release-channels",
            headers: .form(cookie: token),
            beforeRequest: { try $0.content.encode(["channel": channel], as: .urlEncodedForm) }
        ) { status = $0.status }
        return status
    }

    @Test("이름으로 찾아 봇이 있는 채널을 넣는다")
    func addsByName() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub(list: #"{"ok":true,"channels":[{"id":"C0123456789","name":"team-clip","is_member":true}]}"#)
            let (token, appID) = try await seed(on: app, stub: stub)

            #expect(try await add("#Team-Clip", token: token, appID: appID, on: app) == .seeOther)

            let stored = try await ReleaseChannel.query(on: app.db).all()
            #expect(stored.map(\.slackChannelID) == ["C0123456789"])
            #expect(stored.map(\.name) == ["team-clip"])

            // 같은 채널을 두 번 넣어도 한 줄이다.
            #expect(try await add("team-clip", token: token, appID: appID, on: app) == .seeOther)
            #expect(try await ReleaseChannel.query(on: app.db).count() == 1)
        }
    }

    @Test("채널 ID 로도 넣는다")
    func addsByID() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub(info: #"{"ok":true,"channel":{"id":"G0123456789","name":"secret","is_member":true}}"#)
            let (token, appID) = try await seed(on: app, stub: stub)

            #expect(try await add("G0123456789", token: token, appID: appID, on: app) == .seeOther)
            #expect(stub.calls.contains { $0.contains("conversations.info") })
            #expect(try await ReleaseChannel.query(on: app.db).first()?.name == "secret")
        }
    }

    /// 넣을 때 막지 않으면 첫 출시 때에야 실패를 안다. 그때는 다시 올릴 길이 없다.
    @Test("봇이 없는 채널은 넣지 않고 초대하라고 알린다")
    func refusesWhenBotIsNotInvited() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub(list: #"{"ok":true,"channels":[{"id":"C0123456789","name":"team-clip","is_member":false}]}"#)
            let (token, appID) = try await seed(on: app, stub: stub)

            var body = ""
            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/release-channels",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["channel": "team-clip"], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .conflict)
                body = response.body.string
            }
            #expect(body.contains("/invite @alley"))
            #expect(try await ReleaseChannel.query(on: app.db).count() == 0)
        }
    }

    @Test("없는 채널은 넣지 않는다")
    func refusesUnknownChannel() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let (token, appID) = try await seed(on: app, stub: stub)

            #expect(try await add("nowhere", token: token, appID: appID, on: app) == .badRequest)
        }
    }

    @Test("봇이 없는 스토어는 채널 칸 대신 연결을 요청하라고 알린다")
    func noBotShowsRequest() async throws {
        try await withMigratedApp { app in
            let stub = SlackAPIStub()
            let (token, appID) = try await seed(on: app, stub: stub)

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("id=\"release-news\""))
                #expect(html.contains("스토어 관리자에게 봇 연결을 요청하세요"))
                #expect(!html.contains("name=\"channel\""))
                #expect(html.contains("id=\"release-dialog\""))
            }
        }
    }

    @Test("앱 상세에 채널 칸과 출시 팝업이 있다")
    func detailHasSectionAndDialog() async throws {
        try await withMigratedApp(overrides: botEnv) { app in
            let stub = SlackAPIStub()
            let (token, appID) = try await seed(on: app, stub: stub)

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("출시 소식 알림"))
                #expect(html.contains("name=\"channel\""))
                #expect(html.contains("/invite @alley"))
                #expect(html.contains("data-release=\"1.0\""))
                #expect(html.contains("/release-confirm.js"))
            }
        }
    }
}

/// Slack API 를 흉내낸다. 부른 주소와 보낸 본문을 기록하고 정해둔 본문을 돌려준다.
final class SlackAPIStub: Client, @unchecked Sendable {
    private let responses: [String: String]
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedPosts: [String] = []

    init(
        list: String = #"{"ok":true,"channels":[]}"#,
        info: String = #"{"ok":false,"error":"channel_not_found"}"#,
        post: String = #"{"ok":true}"#,
        auth: String = #"{"ok":true,"user":"alley"}"#
    ) {
        responses = [
            "conversations.list": list,
            "conversations.info": info,
            "chat.postMessage": post,
            "auth.test": auth,
        ]
    }

    var calls: [String] {
        lock.withLock { recordedCalls }
    }

    /// `chat.postMessage` 에 보낸 본문들.
    var posts: [String] {
        lock.withLock { recordedPosts }
    }

    var eventLoop: any EventLoop { EmbeddedEventLoop() }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let url = request.url.string
        let method = responses.keys.first { url.contains("/api/\($0)") }
        lock.withLock {
            recordedCalls.append(url)
            if method == "chat.postMessage", var body = request.body {
                recordedPosts.append(body.readString(length: body.readableBytes) ?? "")
            }
        }

        let text = method.flatMap { responses[$0] } ?? #"{"ok":false,"error":"unknown_method"}"#
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return eventLoop.makeSucceededFuture(ClientResponse(status: .ok, headers: headers, body: buffer))
    }
}
