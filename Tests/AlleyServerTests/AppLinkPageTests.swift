import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 앱 하나를 사람에게 건네는 공유 페이지 (ADR-0072).
@Suite("앱 공유 페이지")
struct AppLinkPageTests {
    /// 출시본이 있는 앱. 아이콘과 한 줄 소개까지 채운다.
    private func seedReleased(on app: Application) async throws -> App {
        let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
        record.summary = "한 줄로 적는 메모"
        record.iconURL = "/apps/\(try record.requireID().uuidString)/icon.png?v=1"
        try await record.save(on: app.db)
        try await app.seedVersion(
            appID: try record.requireID(), short: "1.0", build: 1, state: .released, by: owner
        )
        return record
    }

    /// 받는 사람은 로그인하지 않은 채로 링크를 누른다. 웹으로 로그인시키면 개발자가 된다
    /// (ADR-0056).
    @Test("출시된 앱은 로그인 없이 보이고 스토어 앱을 부른다")
    func releasedAppOpensWithoutLogin() async throws {
        try await withMigratedApp { app in
            let record = try await seedReleased(on: app)
            let appID = try record.requireID()
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            let scheme = settings.urlScheme

            try await app.testing().test(.GET, AppLink.webPath(appID: appID)) { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains("메모장"))
                #expect(html.contains("한 줄로 적는 메모"))
                #expect(html.contains("\(scheme)://apps/\(appID.uuidString.lowercased())"))
                #expect(html.contains("href=\"/get\""))
                #expect(html.contains("/app-link.js"))
                // 버튼에는 조직이 정한 스토어 앱 이름을 적는다.
                #expect(html.contains("\(settings.appName)에서 보기"))
                #expect(html.contains("\(settings.appName) 다운로드"))
            }
        }
    }

    /// 버튼은 스크립트가 꺼낸다. 스크립트가 없는 브라우저에서도 누를 것이 있어야 한다.
    @Test("버튼은 처음에 숨어 있고 스크립트가 없으면 보인다")
    func buttonsWaitForTheScript() async throws {
        try await withMigratedApp { app in
            let record = try await seedReleased(on: app)

            try await app.testing().test(.GET, AppLink.webPath(appID: try record.requireID())) { response in
                let html = response.body.string
                #expect(html.contains("data-app-link-actions hidden"))
                #expect(html.contains("<noscript>"))
                #expect(html.contains("여는 중입니다"))
            }
        }
    }

    /// 미리보기 카드를 그리는 쪽은 브라우저가 아니다. 상대 주소로는 그림을 찾지 못한다.
    @Test("미리보기 태그는 절대 주소를 쓴다")
    func previewTagsUseAbsoluteURLs() async throws {
        try await withMigratedApp { app in
            let record = try await seedReleased(on: app)
            let appID = try record.requireID()

            try await app.testing().test(.GET, AppLink.webPath(appID: appID)) { response in
                let html = response.body.string
                #expect(html.contains("<meta property=\"og:title\" content=\"메모장\">"))
                #expect(html.contains("<meta property=\"og:description\" content=\"한 줄로 적는 메모\">"))
                #expect(html.contains(
                    "content=\"https://store.example.com/apps/\(appID.uuidString)/icon.png?v=1\""
                ))
                #expect(html.contains(
                    "content=\"https://store.example.com/a/\(appID.uuidString.lowercased())\""
                ))
            }
        }
    }

    /// **출시 전 앱과 없는 앱이 같은 답이어야 한다.** 다르면 주소를 지어서 출시 전
    /// 앱이 있는지 떠볼 수 있다 (ADR-0051).
    @Test("출시 전 앱과 없는 앱은 같은 404 이고 앱 정보가 없다")
    func unreleasedAppLooksLikeNoApp() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let pending = try await app.seedApp(bundleID: "com.example.secret", name: "비밀 프로젝트", owner: owner)
            pending.summary = "아직 말할 수 없는 것"
            try await pending.save(on: app.db)
            try await app.seedVersion(
                appID: try pending.requireID(), short: "0.1", build: 1, state: .ready, by: owner
            )

            var bodies: [String] = []
            for path in [
                AppLink.webPath(appID: try pending.requireID()),
                AppLink.webPath(appID: UUID()),
                "/a/not-a-uuid",
            ] {
                try await app.testing().test(.GET, path) { response in
                    #expect(response.status == .notFound)
                    let html = response.body.string
                    #expect(html.contains("앱을 찾을 수 없습니다"))
                    #expect(!html.contains("비밀 프로젝트"))
                    #expect(!html.contains("아직 말할 수 없는 것"))
                    #expect(!html.contains("og:title"))
                    bodies.append(html)
                }
            }
            #expect(Set(bodies).count == 1)
        }
    }

    /// 스토어 앱 자신은 스토어 앱의 목록에 없다. 링크로 열 상세가 없으니 받는 자리로 보낸다.
    @Test("스토어 앱의 공유 주소는 받기 페이지로 간다")
    func storeAppLinkGoesToGetPage() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, _) = try await StoreAppBootstrapTests.makeStoreApp(on: app, owner: admin)

            try await app.testing().test(.GET, AppLink.webPath(appID: try storeApp.requireID())) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/get")
            }
        }
    }

    /// 스토어 앱의 공유 버튼이 이 값을 그대로 건넨다. 출시 전 앱에 주소를 주면 받은
    /// 사람은 "앱을 찾을 수 없습니다" 를 본다.
    @Test("목록 API 는 출시된 앱에만 공유 주소를 준다")
    func shareURLOnlyForReleasedApps() async throws {
        try await withMigratedApp { app in
            let record = try await seedReleased(on: app)
            let owner = try #require(try await User.query(on: app.db).first())
            let pending = try await app.seedApp(bundleID: "com.example.wip", name: "준비 중", owner: owner)
            let (_, session) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(.GET, APIPath.apps, headers: .sessionCookie(session)) { response in
                let apps = try response.content.decode([AppDTO].self)
                let released = try #require(apps.first { $0.id == (try? record.requireID()) })
                let unreleased = try #require(apps.first { $0.id == (try? pending.requireID()) })
                #expect(released.shareURL
                    == "https://store.example.com/a/\(try record.requireID().uuidString.lowercased())")
                #expect(unreleased.shareURL == nil)
            }
        }
    }
}
