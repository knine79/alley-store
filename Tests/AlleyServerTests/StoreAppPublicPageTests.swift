import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 스토어 앱을 로그인 없이 받는 공개 페이지 (ADR-0049).
///
/// **콘솔과 보는 사람이 다르다.** `/apps` 는 앱을 올리는 사람이 보는 화면이라,
/// 받으러 온 사람에게 그 주소를 알려주면 개발자용 화면에 먼저 떨어진다.
@Suite("스토어 앱 공개 페이지")
struct StoreAppPublicPageTests {
    /// 출시되고 **서명까지 끝난** 스토어 앱.
    ///
    /// 서버가 빌드한 것은 언제나 미서명이고, 서명본은 워커가 붙인다. 공개 페이지는
    /// 그 서명본만 내주므로 픽스처도 거기까지 맞춘다.
    static func makeSignedStoreApp(
        on app: Application,
        owner: User
    ) async throws -> (App, Version) {
        let (storeApp, version) = try await StoreAppBootstrapTests.makeStoreApp(
            on: app, owner: owner
        )
        let key = "apps/test/\(try version.requireID().uuidString)/signed.zip"
        try await app.artifactStorage.put(
            Data("서명된 zip 이라고 치자".utf8), to: key, contentType: "application/zip"
        )
        try await Artifact(
            versionID: try version.requireID(),
            kind: .signed,
            storageKey: key,
            sha256: nil,
            fileSize: 32
        ).save(on: app.db)
        try await version.$artifacts.load(on: app.db)
        return (storeApp, version)
    }

    /// 로그인을 요구하면 순서가 막힌다. 받으러 온 사람이 하려는 일은 하나뿐이다.
    @Test("로그인 없이 열리고 받기 링크가 있다")
    func pageOpensWithoutLogin() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, _) = try await Self.makeSignedStoreApp(on: app, owner: admin)

            try await app.testing().test(.GET, "/get") { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains(storeApp.name))
                #expect(html.contains("/get/download"))
            }
        }
    }

    /// 세션이 없어도 받아간 사실은 남는다. 사람을 모르는 것과 받아간 사실을
    /// 모르는 것은 다르다.
    @Test("로그인 없이 받으면 익명으로 이력이 남는다")
    func anonymousDownloadIsRecorded() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = try await Self.makeSignedStoreApp(on: app, owner: admin)

            try await app.testing().test(.GET, "/get/download") { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("storage.example"))
            }

            let downloads = try await Download.query(on: app.db).all()
            #expect(downloads.count == 1)
            #expect(downloads.first?.$user.id == nil)
        }
    }

    /// 같은 경로라도 세션이 있으면 그 사람을 적는다. 알 수 있는 것을 버리지 않는다.
    @Test("로그인해 있으면 그 사람으로 남는다")
    func loggedInDownloadKeepsTheUser() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = try await Self.makeSignedStoreApp(on: app, owner: admin)
            let (user, token) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .GET, "/get/download", headers: .sessionCookie(token)
            ) { #expect($0.status == .seeOther) }

            let downloads = try await Download.query(on: app.db).all()
            #expect(downloads.count == 1)
            #expect(downloads.first?.$user.id == (try user.requireID()))
        }
    }

    /// **출시본만 내준다.** 서명·공증 전인 것을 내보내면 받은 사람의 맥이 열지
    /// 못하고, 그 사람은 앱이 깨졌다고 생각한다.
    @Test("출시본이 없으면 받기 링크도 경로도 없다")
    func unreleasedStoreAppIsNotOffered() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = try await StoreAppBootstrapTests.makeStoreApp(
                on: app, owner: admin, released: false
            )

            try await app.testing().test(.GET, "/get") { response in
                #expect(response.status == .ok)
                #expect(!response.body.string.contains("/get/download"))
            }

            // 화면이 안 그린다고 경로가 막히는 것은 아니다. 여는 조건은 서버가 기준이다.
            try await app.testing().test(.GET, "/get/download") { response in
                #expect(response.status == .notFound)
            }

            let downloads = try await Download.query(on: app.db).count()
            #expect(downloads == 0)
        }
    }

    /// 스토어 앱을 아직 한 번도 빌드하지 않은 서버다. 404 로 떨어뜨리지 않고
    /// 무슨 일인지 적는다. 받으러 온 사람은 주소를 잘못 안 것이 아니다.
    @Test("스토어 앱이 없어도 화면은 열린다")
    func pageOpensWithoutAStoreApp() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/get") { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("아직 받을 수 있는 앱이 없습니다"))
            }
        }
    }

    /// **익명 줄이 사람 수를 부풀리면 안 된다.** `COUNT(DISTINCT user_id)` 가
    /// NULL 을 빼고 세는 데 기대고 있어서, 그 전제가 깨지면 여기서 걸린다.
    @Test("익명 다운로드는 횟수에만 들어가고 사람 수에는 안 들어간다")
    func anonymousDownloadsCountOnlyAsDownloads() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, _) = try await Self.makeSignedStoreApp(on: app, owner: admin)
            let (_, token) = try await app.makeUser(email: "user@example.com", role: .user)

            // 익명 둘, 사람 하나.
            try await app.testing().test(.GET, "/get/download") { #expect($0.status == .seeOther) }
            try await app.testing().test(.GET, "/get/download") { #expect($0.status == .seeOther) }
            try await app.testing().test(
                .GET, "/get/download", headers: .sessionCookie(token)
            ) { #expect($0.status == .seeOther) }

            let summary = try await DownloadStats.summary(
                ofApp: try storeApp.requireID(), on: app.db
            )
            #expect(summary.total == 3)
            #expect(summary.people == 1)
        }
    }

    /// **미서명본으로 폴백하지 않는다.** `bestArtifact` 는 서명본이 없으면 올린 그대로를
    /// 준다. 콘솔에서는 올린 사람이 자기 빌드를 보는 자리라 맞지만, 여기는 아무것도
    /// 모르는 사람이 받는 자리다. 미서명 앱은 Gatekeeper 가 막고, 막힌 사람은
    /// "앱이 깨졌구나" 라고 생각한다.
    @Test("출시됐어도 서명본이 없으면 내주지 않는다")
    func releasedButUnsignedIsNotOffered() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            // 서버가 빌드한 그대로다. 출시까지 됐지만 워커가 서명본을 붙이지 않았다.
            let (_, version) = try await StoreAppBootstrapTests.makeStoreApp(on: app, owner: admin)
            try await version.$artifacts.load(on: app.db)
            #expect(version.artifacts.allSatisfy { $0.kind == .unsigned })

            try await app.testing().test(.GET, "/get") { response in
                #expect(response.status == .ok)
                #expect(!response.body.string.contains("/get/download"))
            }
            try await app.testing().test(.GET, "/get/download") { response in
                #expect(response.status == .notFound)
            }
            #expect(try await Download.query(on: app.db).count() == 0)
        }
    }

    /// **오브젝트 키가 곧 파일 이름이 된다.** 그대로 내보내면 받는 사람의 내려받기
    /// 폴더에 `signed.zip` 이 쌓이고, 두 번 받으면 `signed (2).zip` 이 된다. 무엇을
    /// 받았는지 알 수 없다.
    @Test("받는 파일 이름에 앱 이름과 버전이 들어간다")
    func downloadCarriesAReadableFilename() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, version) = try await Self.makeSignedStoreApp(on: app, owner: admin)

            let expected = StoreAppGetController.downloadFilename(app: storeApp, version: version)
            #expect(expected == "\(storeApp.name) \(version.shortVersion).zip")

            try await app.testing().test(.GET, "/get/download") { response in
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("response-content-disposition"))
            }
        }
    }

    /// 한글 앱 이름이 흔하다. ASCII 로 접은 벌만 실으면 이름이 통째로 `-` 가 된다.
    @Test("한글 이름은 RFC 5987 벌을 함께 싣는다")
    func koreanFilenameCarriesBothForms() throws {
        let disposition = try #require(
            ArtifactStorage.contentDisposition(for: "앱 스토어 1.0.0.zip")
        )
        #expect(disposition.hasPrefix("attachment; filename="))
        // ASCII 벌은 확장자를 남긴다.
        #expect(disposition.contains(".zip"))
        // 원래 이름은 퍼센트 인코딩으로 남는다.
        #expect(disposition.contains("filename*=UTF-8''"))
    }
}
