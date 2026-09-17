import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 스토어 앱을 웹에서 받는 길 (이슈 #17).
///
/// **스토어 앱이 없는 사람에게는 이것이 유일한 길이다.** 그래서 열지만, 모든 앱에
/// 열지는 않는다. 웹 다운로드는 스토어 앱이 하는 검증 중 "이미 깔린 같은 앱과
/// 서명한 팀이 같은가" 를 건너뛴다. 그 판단은 로컬에 무엇이 깔렸는지 알아야만 할 수
/// 있어서 브라우저에서는 재현할 수 없다.
@Suite("스토어 앱 부트스트랩")
struct StoreAppBootstrapTests {
    /// 스토어 앱으로 등록되고 출시본이 하나 있는 상태를 만든다.
    static func makeStoreApp(
        on app: Application,
        owner: User,
        released: Bool = true
    ) async throws -> (App, Version) {
        let storage = app.useFakeStorage()
        let settings = try await StoreAppSettings.loadOrSeed(
            on: app.db, config: app.alleyConfig, logger: app.logger
        )
        settings.bundleID = "com.example.alley.store"
        settings.appName = "우리 스토어"
        try await settings.save(on: app.db)

        try await StoreAppBuildService.acceptBaseBundle(
            version: "0.4.0",
            data: StoreAppBundleRewriterTests.baseZip(),
            settings: settings,
            by: owner,
            storage: storage,
            on: app.db,
            logger: app.logger
        )
        let result = try await StoreAppBuildService.build(
            settings: settings,
            icon: nil,
            serverURL: "https://store.example.com",
            by: owner,
            storage: storage,
            on: app.db,
            directory: app.directory,
            logger: app.logger
        )

        let version = try #require(try await Version.find(result.versionID, on: app.db))
        if released {
            // 실제로는 워커가 서명·공증을 마친 뒤에 지나는 길이다. 여기서는 그
            // 구간을 건너뛰고 상태만 맞춘다.
            try version.transition(to: .signing)
            try version.transition(to: .notarizing)
            try version.transition(to: .ready)
            try version.transition(to: .released)
            try await version.save(on: app.db)
        }

        let storeApp = try #require(try await App.find(result.appID, on: app.db))
        return (storeApp, version)
    }

    /// 스토어 앱이 아닌 보통 앱. 받을 파일이 실제로 있어야 링크 조건이 의미를 갖는다.
    static func makeOrdinaryApp(on app: Application, owner: User) async throws -> (App, Version) {
        app.useFakeStorage()
        let record = try await app.seedApp(
            bundleID: "com.example.other", name: "다른 앱", owner: owner
        )
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: .released, by: owner
        )
        try await Self.attachArtifact(to: version, on: app)
        return (record, version)
    }

    /// 받을 파일이 없으면 링크를 그리지 않는다. 그 조건에 걸려 시험이 통과하는 일을
    /// 막으려고 픽스처에 아티팩트를 붙인다.
    static func attachArtifact(to version: Version, on app: Application) async throws {
        let key = "apps/test/\(try version.requireID().uuidString)/unsigned.zip"
        try await app.artifactStorage.put(Data("zip 이라고 치자".utf8), to: key, contentType: "application/zip")
        try await Artifact(
            versionID: try version.requireID(),
            kind: .unsigned,
            storageKey: key,
            sha256: nil,
            fileSize: 16
        ).save(on: app.db)
        try await version.$artifacts.load(on: app.db)
    }

    /// **스토어 앱은 목록에 서지 않는다.** 다른 앱을 받는 도구라 같은 줄에 두면
    /// 안 된다. 대신 받는 자리는 남는다. 스토어 앱이 없는 사람에게는 그것이 유일한
    /// 입구라, 목록에서 뺐다고 받을 길까지 없애면 아무도 시작할 수 없다.
    @Test("목록에 줄로 서지 않고 받는 자리만 둔다")
    func storeAppIsNotListedButDownloadable() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, version) = try await Self.makeStoreApp(on: app, owner: admin)
            let (_, token) = try await app.makeUser(email: "user@example.com", role: .user)

            let appPath = "/apps/\(try storeApp.requireID().uuidString)"
            _ = version

            try await app.testing().test(.GET, "/apps", headers: .sessionCookie(token)) { response in
                let html = response.body.string
                #expect(response.status == .ok)
                // 목록의 줄(카드)로는 없다. 카드 링크는 주소가 따옴표로 끝난다.
                #expect(!html.contains("\(appPath)\""))
                // 받는 자리는 있다. **공개 페이지 하나를 가리킨다** (ADR-0050).
                // 버전 경로를 따로 가리키면 그쪽은 zip 을 주고 공개 페이지는 dmg 를
                // 줘서, 같은 줄에서 누른 것이 어디로 갔느냐에 따라 달라진다.
                #expect(html.contains("여기서 다운로드 받으세요"))
                #expect(html.contains("href=\"/get\""))
                #expect(!html.contains("/versions/"))
            }
        }
    }

    /// 스토어 앱에 관한 일은 관리 > 스토어 앱 한 화면에서 끝난다. 상세를 남겨두면
    /// 무엇을 어디서 하는지가 갈린다.
    @Test("스토어 앱 상세는 관리 화면으로 보낸다")
    func storeAppDetailRedirects() async throws {
        try await withMigratedApp { app in
            let (admin, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, _) = try await Self.makeStoreApp(on: app, owner: admin)
            let path = "/apps/\(try storeApp.requireID().uuidString)"

            try await app.testing().test(.GET, path, headers: .sessionCookie(adminToken)) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/admin/store-app")
            }

            // 관리자가 아니면 그 화면에 못 들어간다. 목록으로 보낸다.
            let (_, token) = try await app.makeUser(email: "user@example.com", role: .user)
            try await app.testing().test(.GET, path, headers: .sessionCookie(token)) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/apps")
            }
        }
    }

    /// **스토어 앱이 하는 일을 우회하는 기본 경로를 만들지 않는다.**
    @Test("보통 앱에는 받기 링크가 없다")
    func ordinaryAppsHaveNoDownloadLink() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (ordinary, version) = try await Self.makeOrdinaryApp(on: app, owner: owner)

            let (_, token) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .GET, "/apps/\(try ordinary.requireID().uuidString)",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(!response.body.string.contains("이 버전 받기"))
            }

            // 화면이 안 그려도 경로는 열려 있을 수 있다. 여는 조건은 서버가 기준이다.
            try await app.testing().test(
                .GET,
                "/apps/\(try ordinary.requireID().uuidString)/versions/\(try version.requireID().uuidString)/download",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// 스토어 앱이 깨졌을 때 우회할 길이 없어지는 것이 유일한 걱정이었다. 올린
    /// 사람에게는 열어두면 그 걱정도 덜린다.
    @Test("올릴 권한이 있으면 자기 앱은 웹에서 받을 수 있다")
    func uploadersCanDownloadTheirOwnApps() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (ordinary, version) = try await Self.makeOrdinaryApp(on: app, owner: owner)

            try await app.testing().test(
                .GET,
                "/apps/\(try ordinary.requireID().uuidString)/versions/\(try version.requireID().uuidString)/download",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("storage.example"))
            }
        }
    }

    /// 어디로 받았든 "누가 언제 무엇을 받았나" 는 같은 표에 있어야 한다.
    @Test("웹으로 받아도 이력이 남는다")
    func webDownloadIsRecorded() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            // 공개 페이지는 서명본만 내준다 (ADR-0049). 픽스처도 거기까지 맞춘다.
            let (storeApp, version) = try await StoreAppPublicPageTests.makeSignedStoreApp(
                on: app, owner: admin
            )
            let (user, token) = try await app.makeUser(email: "user@example.com", role: .user)

            // 받으러 온 사람은 공개 페이지로 보낸다 (ADR-0050). 옛 주소를 들고
            // 와도 받는 것은 같아야 한다.
            try await app.testing().test(
                .GET,
                "/apps/\(try storeApp.requireID().uuidString)/versions/\(try version.requireID().uuidString)/download",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/get/download")
            }

            // 브라우저는 그 리다이렉트를 따라간다. 이력은 거기서 남는다.
            try await app.testing().test(
                .GET, "/get/download", headers: .sessionCookie(token)
            ) { #expect($0.status == .seeOther) }

            let downloads = try await Download.query(on: app.db).all()
            #expect(downloads.count == 1)
            #expect(downloads.first?.$user.id == (try user.requireID()))
        }
    }

    /// 출시 전 버전은 스토어 앱이어도 아무나 받을 수 없다.
    @Test("출시하지 않은 스토어 앱 버전은 못 받는다")
    func unreleasedStoreAppIsNotDownloadable() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, version) = try await Self.makeStoreApp(
                on: app, owner: admin, released: false
            )
            let (_, token) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .GET,
                "/apps/\(try storeApp.requireID().uuidString)/versions/\(try version.requireID().uuidString)/download",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
