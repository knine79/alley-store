import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("appcast XML")
struct AppcastXMLTests {
    private func item(
        shortVersion: String = "1.2.0",
        build: Int = 42,
        notes: String? = nil,
        signature: String? = "sig=="
    ) -> Appcast.Item {
        Appcast.Item(
            shortVersion: shortVersion,
            buildNumber: build,
            releaseNotes: notes,
            minimumSystemVersion: "14.0",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            downloadURL: "https://storage.example/app.zip?sig=abc",
            fileSize: 12345,
            edSignature: signature
        )
    }

    @Test("Sparkle 이 읽는 항목을 담는다")
    func buildsExpectedFields() {
        let xml = Appcast.xml(appName: "메모장", items: [item()])

        #expect(xml.contains("<sparkle:version>42</sparkle:version>"))
        #expect(xml.contains("<sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>"))
        #expect(xml.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
        #expect(xml.contains("length=\"12345\""))
        #expect(xml.contains("sparkle:edSignature=\"sig==\""))
    }

    @Test("XML 에서 뜻을 갖는 문자를 바꾼다")
    func escapesSpecialCharacters() {
        // 앱 이름에 & 하나가 들어가면 Sparkle 이 피드 전체를 못 읽는다.
        // 업데이트가 조용히 멈추고 아무도 모른다.
        let xml = Appcast.xml(
            appName: "메모 & 할 일",
            items: [item(notes: "<b>굵게</b> 그리고 \"따옴표\"")]
        )

        #expect(xml.contains("메모 &amp; 할 일"))
        #expect(xml.contains("&lt;b&gt;굵게&lt;/b&gt;"))
        #expect(xml.contains("&quot;따옴표&quot;"))
        // 이스케이프하지 않은 원본이 남아 있으면 안 된다.
        #expect(!xml.contains("<b>굵게"))
    }

    @Test("다운로드 주소의 & 도 바꾼다")
    func escapesURLAmpersand() {
        var withQuery = item()
        withQuery.downloadURL = "https://storage.example/app.zip?a=1&b=2"
        let xml = Appcast.xml(appName: "도구", items: [withQuery])

        // presigned URL 에는 질의 항목이 여럿이라 & 가 반드시 들어간다.
        #expect(xml.contains("a=1&amp;b=2"))
    }

    @Test("서명이 없으면 그 속성을 빼고 만든다")
    func omitsMissingSignature() {
        let xml = Appcast.xml(appName: "도구", items: [item(signature: nil)])
        #expect(!xml.contains("edSignature"))
    }

    @Test("날짜를 RFC 822 로 쓴다")
    func formatsDate() {
        // 시스템 로케일을 따르면 한국어 환경에서 "9월"처럼 나가고 그건 RFC 822 가 아니다.
        let formatted = Appcast.rfc822(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(formatted.hasSuffix("+0000"))
        #expect(formatted.contains("Jan") || formatted.contains("2027"))
    }

    @Test("항목이 없어도 유효한 피드를 만든다")
    func handlesEmptyFeed() {
        let xml = Appcast.xml(appName: "도구", items: [])
        #expect(xml.contains("<channel>"))
        #expect(xml.contains("</rss>"))
        #expect(!xml.contains("<item>"))
    }
}

@Suite("피드 토큰")
struct FeedTokenTests {
    private func seed(
        on app: Application
    ) async throws -> (owner: User, ownerToken: String, appID: UUID, feed: String) {
        let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let appID = try record.requireID()
        let version = try await app.seedVersion(
            appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
        )
        try await Artifact(
            versionID: try version.requireID(),
            kind: .signed,
            storageKey: "apps/x/signed.zip",
            sha256: "abc",
            fileSize: 1024
        ).save(on: app.db)

        let created = try await FeedTokenIssuing.issue(
            named: "sparkle",
            for: record,
            by: owner,
            baseURL: "https://store.example.com",
            on: app.db,
            logger: app.logger
        )
        return (owner, ownerToken, appID, created.value)
    }

    private func feedPath(_ appID: UUID, token: String) -> String {
        APIPath.appcast(ofApp: appID, token: token)
    }

    private func legacyFeedPath(_ appID: UUID, token: String) -> String {
        "\(APIPath.legacyAppcast(ofApp: appID))?\(APIPath.feedTokenQueryItem)=\(token)"
    }

    @Test("토큰이 있으면 로그인 없이 피드를 준다")
    func servesFeedWithToken() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)

            // Sparkle 은 세션도 헤더도 들고 있지 않다.
            try await app.testing().test(
                .GET, feedPath(seeded.appID, token: seeded.feed)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers.contentType?.subType == "rss+xml")
                #expect(response.body.string.contains("<sparkle:version>1</sparkle:version>"))
            }
        }
    }

    @Test("토큰이 없거나 틀리면 앱이 있는지도 알려주지 않는다", arguments: ["", "alleyf_wrong"])
    func hidesFeedWithoutToken(_ token: String) async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)

            try await app.testing().test(
                .GET, feedPath(seeded.appID, token: token)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("다른 앱의 토큰으로는 열 수 없다")
    func tokenIsScopedToApp() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)
            let other = try await app.seedApp(
                bundleID: "com.example.other", name: "다른 앱", owner: seeded.owner
            )

            try await app.testing().test(
                .GET, feedPath(try other.requireID(), token: seeded.feed)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("폐기하면 피드가 닫힌다")
    func revokedTokenStops() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)
            let stored = try #require(try await FeedToken.query(on: app.db).first())
            let record = try #require(try await App.find(seeded.appID, on: app.db))

            try await FeedTokenIssuing.revoke(
                try stored.requireID(),
                ofApp: record,
                by: seeded.owner,
                on: app.db,
                logger: app.logger
            )

            try await app.testing().test(
                .GET, feedPath(seeded.appID, token: seeded.feed)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("출시본만 나간다")
    func onlyReleasedVersions() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)
            let pending = try await app.seedVersion(
                appID: seeded.appID, short: "2.0.0", build: 9, state: .ready, by: seeded.owner
            )
            try await Artifact(
                versionID: try pending.requireID(),
                kind: .signed, storageKey: "apps/y/signed.zip", sha256: "def", fileSize: 2048
            ).save(on: app.db)

            // 출시 전 버전 번호가 새어나가면 알려지지 않아야 할 일정이 드러난다.
            try await app.testing().test(
                .GET, feedPath(seeded.appID, token: seeded.feed)
            ) { #expect(!$0.body.string.contains("2.0.0")) }
        }
    }

    @Test("발급하면 그대로 쓸 수 있는 주소를 준다")
    func givesReadyToUseURL() async throws {
        try await withMigratedApp { app in
            let seeded = try await seed(on: app)
            let record = try #require(try await App.find(seeded.appID, on: app.db))
            let created = try await FeedTokenIssuing.issue(
                named: "두 번째",
                for: record,
                by: seeded.owner,
                baseURL: "https://store.example.com/",
                on: app.db,
                logger: app.logger
            )

            // 사람이 손으로 붙이면 실수가 난다.
            #expect(created.feedURL.hasPrefix("https://store.example.com/api/v1/apps/"))
            #expect(created.feedURL.contains("/feed/alleyf_"))
            #expect(created.feedURL.hasSuffix("/appcast.xml"))
            // 새로 내주는 주소에는 질의 형식이 남아 있으면 안 된다.
            #expect(!created.feedURL.contains("?"))
            // 슬래시가 겹치지 않아야 한다.
            #expect(!created.feedURL.contains("com//api"))
        }
    }

    @Test("이미 배포된 앱을 위해 옛 질의 형식도 아직 받는다")
    func stillServesLegacyQueryURL() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)

            // 여기서 끊으면 이미 깔린 앱들이 조용히 업데이트를 멈춘다.
            try await app.testing().test(
                .GET, legacyFeedPath(seeded.appID, token: seeded.feed)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("<sparkle:version>1</sparkle:version>"))
                // 폐기 예정이라고 응답에 적어둔다.
                #expect(response.headers.first(name: "Deprecation") == "true")
            }
        }
    }

    @Test("새 형식 응답에는 폐기 표시가 붙지 않는다")
    func newURLIsNotMarkedDeprecated() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)

            try await app.testing().test(
                .GET, feedPath(seeded.appID, token: seeded.feed)
            ) { #expect($0.headers.first(name: "Deprecation") == nil) }
        }
    }

    @Test("경로에 실린 토큰이 틀리면 앱이 있는지도 알려주지 않는다")
    func hidesFeedForWrongPathToken() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)

            try await app.testing().test(
                .GET, feedPath(seeded.appID, token: "alleyf_wrong")
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("피드 토큰으로 다른 API 를 열 수 없다")
    func feedTokenIsReadOnly() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)

            // 이 토큰으로 할 수 있는 것은 그 앱의 출시본을 보고 받는 것뿐이다.
            try await app.testing().test(
                .GET, APIPath.apps, headers: .bearer(seeded.feed)
            ) { #expect($0.status == .unauthorized) }
            try await app.testing().test(
                .GET, "\(APIPath.adminRoot)/settings", headers: .bearer(seeded.feed)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("화면에서 발급하면 주소가 한 번만 보인다")
    func consoleShowsFeedOnce() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let seeded = try await seed(on: app)
            let path = "/apps/\(seeded.appID.uuidString)"

            try await app.testing().test(
                .POST, "\(path)/feed-tokens", headers: .form(cookie: seeded.ownerToken),
                beforeRequest: { request in
                    try request.content.encode(["name": "sparkle-2"], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .created)
                // 화면도 새 형식으로 낸다. 옛 형식이 여기서 새로 퍼지면 안 된다.
                #expect(response.body.string.contains("/feed/alleyf_"))
                #expect(!response.body.string.contains("appcast.xml?token="))
            }

            try await app.testing().test(
                .GET, path, headers: .sessionCookie(seeded.ownerToken)
            ) { #expect(!$0.body.string.contains("alleyf_")) }
        }
    }
}

@Suite("Sparkle 서명")
struct SparkleSignatureTests {
    @Test("피드에 워커가 보고한 서명이 실린다")
    func feedCarriesWorkerSignature() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
            )
            let artifact = Artifact(
                versionID: try version.requireID(),
                kind: .signed, storageKey: "apps/x/signed.zip", sha256: "abc", fileSize: 1024
            )
            artifact.edSignature = "AbCdEf=="
            try await artifact.save(on: app.db)

            let created = try await FeedTokenIssuing.issue(
                named: "sparkle", for: record, by: owner,
                baseURL: "https://store.example.com", on: app.db, logger: app.logger
            )

            // 서명이 없으면 Sparkle 이 설치를 거부한다.
            try await app.testing().test(
                .GET, APIPath.appcast(ofApp: appID, token: created.value)
            ) { #expect($0.body.string.contains("sparkle:edSignature=\"AbCdEf==\"")) }
        }
    }
}
