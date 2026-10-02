import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 앱 상세에 스크린샷을 둔다 (이슈 #40).
@Suite("앱 스크린샷")
struct AppScreenshotTests {
    private struct Upload: Content {
        var images: [File]
    }

    private func upload(
        _ data: Data, filename: String = "shot.png", to appID: UUID, token: String, on app: Application
    ) async throws -> HTTPStatus {
        try await upload([(data, filename)], to: appID, token: token, on: app)
    }

    private func upload(
        _ files: [(Data, String)], to appID: UUID, token: String, on app: Application
    ) async throws -> HTTPStatus {
        var status = HTTPStatus.ok
        try await app.testing().test(
            .POST, "/apps/\(appID.uuidString)/screenshots", headers: .form(cookie: token),
            beforeRequest: { request in
                try request.content.encode(
                    Upload(images: files.map { File(data: .init(data: $0.0), filename: $0.1) }),
                    as: .formData
                )
            }
        ) { status = $0.status }
        return status
    }

    private func seed(_ app: Application) async throws -> (App, String) {
        _ = app.useFakeStorage()
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
        return (seeded, token)
    }

    @Test("올린 스크린샷은 로그인한 사람에게만 내준다")
    func uploadsAndServesToSignedIn() async throws {
        try await withMigratedApp { app in
            let (seeded, token) = try await seed(app)
            let appID = try seeded.requireID()
            let png = PNGFixture.png(width: 1280, height: 800)

            #expect(try await upload(png, to: appID, token: token, on: app) == .seeOther)

            let stored = try #require(try await App.find(appID, on: app.db))
            #expect(stored.screenshotKeys.count == 1)
            let dto = try stored.toDTO()
            let address = try #require(dto.screenshotURLs?.first)
            #expect(address.hasPrefix(APIPath.app(appID) + "/screenshots/"))

            try await app.testing().test(.GET, address) {
                #expect($0.status == .unauthorized)
            }
            let (_, readerToken) = try await app.makeUser(email: "user@example.com", role: .user)
            // 출시 전에는 손댈 수 있는 사람에게만 보인다 (ADR-0051).
            try await app.testing().test(.GET, address, headers: .bearer(readerToken)) {
                #expect($0.status == .notFound)
            }
            try await app.testing().test(.GET, address, headers: .sessionCookie(token)) {
                #expect($0.status == .ok)
            }

            let owner = try #require(try await User.query(on: app.db).filter(\.$email == "dev@example.com").first())
            _ = try await app.seedVersion(appID: appID, short: "1.0", build: 1, state: .released, by: owner)
            try await app.testing().test(.GET, address, headers: .bearer(readerToken)) { response in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .contentType) == "image/png")
                #expect(Data(buffer: response.body) == png)
            }
        }
    }

    @Test("JPEG 도 받고, 그림이 아닌 것은 거절한다")
    func checksFormatByContent() async throws {
        try await withMigratedApp { app in
            let (seeded, token) = try await seed(app)
            let appID = try seeded.requireID()

            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(count: 64)
            #expect(try await upload(jpeg, filename: "shot.jpg", to: appID, token: token, on: app) == .seeOther)
            // 이름만 그림인 것.
            #expect(try await upload(Data("text".utf8), filename: "fake.png", to: appID, token: token, on: app) == .badRequest)

            let stored = try #require(try await App.find(appID, on: app.db))
            #expect(stored.screenshotKeys.count == 1)
            #expect(stored.screenshotKeys[0].hasSuffix(".jpg"))
        }
    }

    @Test("여러 장을 한 번에 올리고, 하나라도 틀리면 아무것도 올리지 않는다")
    func uploadsSeveralAtOnce() async throws {
        try await withMigratedApp { app in
            let (seeded, token) = try await seed(app)
            let appID = try seeded.requireID()
            let png = PNGFixture.png(width: 100, height: 100)

            let mixed = [(png, "a.png"), (Data("text".utf8), "b.png")]
            #expect(try await upload(mixed, to: appID, token: token, on: app) == .badRequest)
            #expect(try await App.find(appID, on: app.db)?.screenshotKeys.isEmpty == true)

            #expect(try await upload([(png, "a.png"), (png, "b.png"), (png, "c.png")], to: appID, token: token, on: app) == .seeOther)
            #expect(try await App.find(appID, on: app.db)?.screenshotKeys.count == 3)

            // 자리는 둘 남았는데 셋을 올리면 앞의 둘만 들어가고 그 사실을 알린다.
            #expect(try await upload([(png, "d.png"), (png, "e.png"), (png, "f.png")], to: appID, token: token, on: app) == .badRequest)
            #expect(try await App.find(appID, on: app.db)?.screenshotKeys.count == AppScreenshots.maximumCount)
        }
    }

    @Test("공동 담당자는 고치는 화면에서 스크린샷만 다룬다")
    func memberSeesScreenshotsOnly() async throws {
        try await withMigratedApp { app in
            let (seeded, _) = try await seed(app)
            let (member, memberToken) = try await app.makeUser(email: "member@example.com", role: .developer)
            try await AppMember(appID: seeded.requireID(), userID: member.requireID()).save(on: app.db)

            try await app.testing().test(
                .GET, "/apps/\(try seeded.requireID().uuidString)/edit", headers: .sessionCookie(memberToken)
            ) { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains(#"id="screenshots""#))
                #expect(!html.contains(#"name="summary""#))
            }
        }
    }

    @Test("다섯 장을 넘기면 거절한다")
    func limitsCount() async throws {
        try await withMigratedApp { app in
            let (seeded, token) = try await seed(app)
            let appID = try seeded.requireID()
            let png = PNGFixture.png(width: 100, height: 100)

            for _ in 0..<AppScreenshots.maximumCount {
                #expect(try await upload(png, to: appID, token: token, on: app) == .seeOther)
            }
            #expect(try await upload(png, to: appID, token: token, on: app) == .badRequest)
        }
    }

    @Test("지우면 목록과 스토리지에서 함께 빠진다")
    func deletes() async throws {
        try await withMigratedApp { app in
            let (seeded, token) = try await seed(app)
            let appID = try seeded.requireID()
            _ = try await upload(PNGFixture.png(width: 100, height: 100), to: appID, token: token, on: app)
            let key = try #require(try await App.find(appID, on: app.db)?.screenshotKeys.first)
            let id = try #require(AppScreenshots.id(fromKey: key))

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/screenshots/\(id.uuidString.lowercased())/delete",
                headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            #expect(try await App.find(appID, on: app.db)?.screenshotKeys.isEmpty == true)
            await #expect(throws: (any Error).self) {
                _ = try await app.artifactStorage.get(key: key, limit: AppScreenshots.maximumSize)
            }
        }
    }

    @Test("올릴 권한이 없는 사람은 올리지 못한다")
    func requiresUploadAccess() async throws {
        try await withMigratedApp { app in
            let (seeded, _) = try await seed(app)
            let (_, otherToken) = try await app.makeUser(email: "other@example.com", role: .developer)

            let status = try await upload(
                PNGFixture.png(width: 100, height: 100), to: try seeded.requireID(), token: otherToken, on: app
            )
            #expect(status == .forbidden)
        }
    }

    @Test("가득 찬 앱에 덧붙이는 것은 데이터베이스가 막는다")
    func appendRespectsLimitAtomically() async throws {
        try await withMigratedApp { app in
            let (seeded, token) = try await seed(app)
            let appID = try seeded.requireID()
            let png = PNGFixture.png(width: 100, height: 100)

            // 동시에 여섯 장. 읽고 고쳐 쓰면 여럿이 검사를 함께 지나 다섯을 넘긴다.
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for _ in 0...AppScreenshots.maximumCount {
                    group.addTask { try await upload(png, to: appID, token: token, on: app) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(statuses.filter { $0 == .seeOther }.count == AppScreenshots.maximumCount)
            let stored = try #require(try await App.find(appID, on: app.db))
            #expect(stored.screenshotKeys.count == AppScreenshots.maximumCount)
        }
    }

    @Test("키에서 주소에 쓰는 ID 를 꺼낸다")
    func idFromKey() {
        let id = UUID()
        let key = AppScreenshots.key(appID: UUID(), id: id, format: .png)
        #expect(AppScreenshots.id(fromKey: "prefix/" + key) == id)
        #expect(AppScreenshots.id(fromKey: "apps/x/icon.png") == nil)
    }
}
