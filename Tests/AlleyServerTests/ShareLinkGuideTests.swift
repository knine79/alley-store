import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 출시하면 콘솔이 공유 링크를 건네게 한다 (이슈 #64).
@Suite("공유 링크 안내")
struct ShareLinkGuideTests {
    private struct Fixture {
        var token: String
        var appID: UUID
        var versionID: UUID
        var link: String { "https://store.example.com/a/\(appID.uuidString.lowercased())" }
    }

    private func seed(on app: Application, state: VersionState = .ready) async throws -> Fixture {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.clip", name: "클립보드 매니저", owner: owner)
        let appID = try record.requireID()
        let version = try await app.seedVersion(appID: appID, short: "1.2", build: 34, state: state, by: owner)
        return Fixture(token: token, appID: appID, versionID: try version.requireID())
    }

    private func detail(_ path: String, token: String, on app: Application) async throws -> String {
        var html = ""
        try await app.testing().test(.GET, path, headers: .sessionCookie(token)) { response in
            #expect(response.status == .ok)
            html = response.body.string
        }
        return html
    }

    @Test("출시하고 돌아오면 공유 링크를 한 번 크게 건넨다")
    func showsLinkRightAfterRelease() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)

            var location = ""
            try await app.testing().test(
                .POST,
                "/apps/\(fixture.appID.uuidString)/versions/\(fixture.versionID.uuidString)/release",
                headers: .form(cookie: fixture.token)
            ) { location = $0.headers.first(name: .location) ?? "" }

            let html = try await detail(location, token: fixture.token, on: app)
            #expect(html.contains("클립보드 매니저 1.2 를 출시했습니다"))
            #expect(html.contains("팀에 알리려면 아래 공유 링크를 건네세요."))
            #expect(html.contains("링크를 누르면 스토어 앱에서 이 앱 상세가 열립니다."))
            #expect(html.contains(fixture.link))
            #expect(html.contains("/copy-button.js"))
        }
    }

    /// 출시 직후로 만든다. 픽스처는 상태만 넣어 출시 시각이 없다.
    private func markReleased(_ fixture: Fixture, at date: Date = Date(), on app: Application) async throws {
        let version = try #require(try await Version.find(fixture.versionID, on: app.db))
        version.releasedAt = date
        try await version.save(on: app.db)
    }

    private func addChannel(_ name: String, to fixture: Fixture, on app: Application) async throws {
        try await ReleaseChannel(
            appID: fixture.appID, slackChannelID: "C\(UUID().uuidString.prefix(10).uppercased())",
            name: name, createdByID: nil
        ).save(on: app.db)
    }

    @Test("출시 소식을 올렸으면 어디에 올렸는지 함께 말한다")
    func mentionsAnnouncedChannels() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app, state: .released)
            try await markReleased(fixture, on: app)
            try await addChannel("team-clip", to: fixture, on: app)
            try await addChannel("design", to: fixture, on: app)

            let html = try await detail(
                "/apps/\(fixture.appID.uuidString)?released=\(fixture.versionID.uuidString)&announced=team-clip,design",
                token: fixture.token, on: app
            )
            #expect(html.contains("#team-clip, #design 에 출시 소식을 올렸습니다."))
        }
    }

    /// 주소를 꾸며 "#전사공지 에 올렸습니다" 같은 거짓 문구를 띄우지 못하게 한다.
    @Test("이 앱에 등록되지 않은 채널 이름은 말하지 않는다")
    func ignoresForgedChannels() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app, state: .released)
            try await markReleased(fixture, on: app)

            let html = try await detail(
                "/apps/\(fixture.appID.uuidString)?released=\(fixture.versionID.uuidString)&announced=%3Cscript%3E,general",
                token: fixture.token, on: app
            )
            #expect(!html.contains("<script>"))
            #expect(!html.contains("general"))
            #expect(html.contains("팀에 알리려면 아래 공유 링크를 건네세요."))
        }
    }

    /// 남아 있던 옛 주소로 들어와도 지난 출시를 다시 알리지 않는다.
    @Test("오래전에 출시한 버전이면 큰 상자를 보여주지 않는다")
    func noBoxForOldRelease() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app, state: .released)
            try await markReleased(fixture, at: Date().addingTimeInterval(-3600), on: app)

            let html = try await detail(
                "/apps/\(fixture.appID.uuidString)?released=\(fixture.versionID.uuidString)",
                token: fixture.token, on: app
            )
            #expect(!html.contains("를 출시했습니다"))
            #expect(html.contains(fixture.link))
        }
    }

    @Test("출시된 앱은 상세에 공유 링크를 늘 둔다")
    func alwaysShowsLinkForReleasedApp() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app, state: .released)

            let html = try await detail("/apps/\(fixture.appID.uuidString)", token: fixture.token, on: app)
            #expect(html.contains("공유 링크"))
            #expect(html.contains(fixture.link))
            // 방금 출시한 것이 아니면 큰 상자는 없다.
            #expect(!html.contains("를 출시했습니다"))
        }
    }

    /// 출시 전 앱의 공유 페이지는 앱 정보를 보여주지 않는다 (ADR-0072).
    @Test("출시 전 앱에는 공유 링크가 없다")
    func noLinkBeforeRelease() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)

            let html = try await detail(
                "/apps/\(fixture.appID.uuidString)?released=\(fixture.versionID.uuidString)",
                token: fixture.token, on: app
            )
            #expect(!html.contains(fixture.link))
            #expect(!html.contains("를 출시했습니다"))
        }
    }

    @Test("API 로 출시하면 결과에 공유 링크가 있다")
    func apiReleaseReturnsLink() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)

            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token)
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(VersionDTO.self)
                #expect(dto.shareURL == fixture.link)
            }
        }
    }

    /// 스토어 앱은 링크로 열 상세가 없다. 사람에게는 `/get` 을 건넨다.
    @Test("스토어 앱을 출시하면 공유 링크를 돌려주지 않는다")
    func storeAppHasNoLink() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            settings.$app.id = fixture.appID
            try await settings.save(on: app.db)

            try await app.testing().test(
                .POST, APIPath.release(versionID: fixture.versionID),
                headers: .bearer(fixture.token)
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(VersionDTO.self)
                #expect(dto.shareURL == nil)
            }
        }
    }
}
