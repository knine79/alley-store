import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 시험용 MP4·MOV. 재생은 안 되지만 서버가 보는 상자(`ftyp`, `moov/mvhd`)는 진짜와 같다.
enum VideoFixture {
    static func box(_ type: String, _ content: Data) -> Data {
        var size = UInt32(8 + content.count).bigEndian
        return Data(bytes: &size, count: 4) + Data(type.utf8) + content
    }

    static func be(_ value: UInt64, size: Int) -> Data {
        Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) })
    }

    static func mvhd(seconds: Double, version: UInt8 = 0) -> Data {
        let timescale: UInt64 = 600
        let duration = UInt64(seconds * Double(timescale))
        var content = Data([version, 0, 0, 0])
        if version == 1 {
            content += be(0, size: 8) + be(0, size: 8) + be(timescale, size: 4) + be(duration, size: 8)
        } else {
            content += be(0, size: 4) + be(0, size: 4) + be(timescale, size: 4) + be(duration, size: 4)
        }
        content += Data(count: 80)
        return box("mvhd", content)
    }

    /// `moovLast` 면 녹화 프로그램처럼 `mdat` 뒤에 `moov` 를 둔다.
    static func make(
        brand: String = "isom", seconds: Double = 12, version: UInt8 = 0, moovLast: Bool = false, padding: Int = 256
    ) -> Data {
        let ftyp = box("ftyp", Data(brand.utf8) + be(0, size: 4) + Data(brand.utf8))
        let moov = box("moov", mvhd(seconds: seconds, version: version))
        let mdat = box("mdat", Data(count: padding))
        return ftyp + (moovLast ? mdat + moov : moov + mdat)
    }
}

@Suite("동영상 머리 읽기")
struct VideoInspectionTests {
    @Test("MP4 와 MOV 를 가리고 길이를 읽는다")
    func readsFormatAndDuration() {
        let mp4 = VideoFixture.make(seconds: 42)
        #expect(VideoInspection.format(of: mp4) == .mp4)
        #expect(VideoInspection.duration(of: mp4) == 42)

        let mov = VideoFixture.make(brand: "qt  ", seconds: 7.5, version: 1, moovLast: true)
        #expect(VideoInspection.format(of: mov) == .mov)
        #expect(VideoInspection.duration(of: mov) == 7.5)
    }

    @Test("동영상이 아니거나 길이가 없으면 모른다고 한다")
    func rejectsNonVideo() {
        #expect(VideoInspection.format(of: Data("hello world, not a movie".utf8)) == nil)
        #expect(VideoInspection.format(of: PNGFixture.png(width: 10, height: 10)) == nil)
        // 머리만 있고 moov 가 없다.
        let headOnly = VideoFixture.box("ftyp", Data("isom".utf8) + Data(count: 4))
        #expect(VideoInspection.format(of: headOnly) == .mp4)
        #expect(VideoInspection.duration(of: headOnly) == nil)
        // 크기가 파일보다 크다고 적힌 상자.
        var broken = VideoFixture.make()
        broken.replaceSubrange(0..<4, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(VideoInspection.format(of: broken) == nil)
    }

    @Test("길이를 사람이 읽는 말로")
    func describesDuration() {
        #expect(VideoInspection.describe(seconds: 42.4) == "42초")
        #expect(VideoInspection.describe(seconds: 84) == "1분 24초")
        #expect(VideoInspection.describe(seconds: 120) == "2분")
    }

    @Test("상한: 60초는 받고 그 넘으면 거절한다")
    func checksLimits() throws {
        #expect(try AppVideos.check(VideoFixture.make(seconds: 60.02)) == .mp4)
        #expect(throws: AppVideos.Rejection.self) { try AppVideos.check(VideoFixture.make(seconds: 61)) }
        #expect(AppVideos.Rejection.tooLong(seconds: 84).reason(name: "demo.mov")
            == "demo.mov 가 60초를 넘습니다 (1분 24초). 줄여서 올리세요.")
        #expect(AppVideos.Rejection.notVideo.reason(name: "demo.webm")
            == "demo.webm 은 MP4 나 MOV 가 아닙니다.")
        #expect(AppVideos.Rejection.tooLarge.reason(name: nil) == "동영상이 50MB 를 넘습니다.")
    }
}

/// 앱 상세에 동영상을 둔다 (이슈 #73).
@Suite("앱 동영상")
struct AppVideoTests {
    private struct Upload: Content {
        var video: File
    }

    private func upload(
        _ data: Data, filename: String = "demo.mp4", to appID: UUID, token: String, on app: Application
    ) async throws -> (HTTPStatus, String) {
        var result = (HTTPStatus.ok, "")
        try await app.testing().test(
            .POST, "/apps/\(appID.uuidString)/video", headers: .form(cookie: token),
            beforeRequest: { request in
                try request.content.encode(
                    Upload(video: File(data: .init(data: data), filename: filename)), as: .formData
                )
            }
        ) { result = ($0.status, $0.body.string) }
        return result
    }

    private func seed(_ app: Application) async throws -> (App, String, FakeArtifactStorage) {
        let storage = app.useFakeStorage()
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
        return (seeded, token, storage)
    }

    @Test("올린 동영상은 로그인한 사람만 스토리지 주소로 넘겨받는다")
    func uploadsAndRedirects() async throws {
        try await withMigratedApp { app in
            let (seeded, token, storage) = try await seed(app)
            let appID = try seeded.requireID()
            let video = VideoFixture.make()

            #expect(try await upload(video, to: appID, token: token, on: app).0 == .seeOther)

            let stored = try #require(try await App.find(appID, on: app.db))
            let key = try #require(stored.videoKey)
            #expect(key.hasSuffix(".mp4"))
            #expect(try await storage.get(key: key, limit: .max) == video)
            let address = try #require(try stored.toDTO().videoURL)
            #expect(address.hasPrefix(APIPath.appVideo(ofApp: appID) + "?v="))

            try await app.testing().test(.GET, address) {
                #expect($0.status == .unauthorized)
            }
            let (_, readerToken) = try await app.makeUser(email: "user@example.com", role: .user)
            // 출시 전에는 손댈 수 있는 사람에게만 (ADR-0051).
            try await app.testing().test(.GET, address, headers: .bearer(readerToken)) {
                #expect($0.status == .notFound)
            }
            let owner = try #require(try await User.query(on: app.db).filter(\.$email == "dev@example.com").first())
            _ = try await app.seedVersion(appID: appID, short: "1.0", build: 1, state: .released, by: owner)
            try await app.testing().test(.GET, address, headers: .bearer(readerToken)) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location)?.hasPrefix("https://storage.example/\(key)") == true)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
        }
    }

    @Test("새로 올리면 앞의 것과 바뀌고 앞의 오브젝트는 지운다")
    func replacesPrevious() async throws {
        try await withMigratedApp { app in
            let (seeded, token, storage) = try await seed(app)
            let appID = try seeded.requireID()

            _ = try await upload(VideoFixture.make(), to: appID, token: token, on: app)
            let first = try #require(try await App.find(appID, on: app.db)?.videoKey)
            _ = try await upload(VideoFixture.make(brand: "qt  "), filename: "demo.mov", to: appID, token: token, on: app)
            let second = try #require(try await App.find(appID, on: app.db)?.videoKey)

            #expect(first != second)
            #expect(second.hasSuffix(".mov"))
            #expect(try await storage.head(key: first) == nil)
            #expect(try await storage.head(key: second) != nil)
        }
    }

    @Test("동영상이 아니거나 60초를 넘으면 거절하고 고치는 화면에 이유를 말한다")
    func rejectsWithReason() async throws {
        try await withMigratedApp { app in
            let (seeded, token, _) = try await seed(app)
            let appID = try seeded.requireID()

            let (badStatus, badBody) = try await upload(Data("text".utf8), filename: "demo.avi", to: appID, token: token, on: app)
            #expect(badStatus == .badRequest)
            #expect(badBody.contains("demo.avi 는 MP4 나 MOV 가 아닙니다."))

            let (longStatus, longBody) = try await upload(VideoFixture.make(seconds: 84), to: appID, token: token, on: app)
            #expect(longStatus == .badRequest)
            #expect(longBody.contains("1분 24초"))

            #expect(try await App.find(appID, on: app.db)?.videoKey == nil)
        }
    }

    @Test("API 로 갈아끼우고 지우며 앱을 돌려준다")
    func apiPutAndDelete() async throws {
        try await withMigratedApp { app in
            let (seeded, _, storage) = try await seed(app)
            let appID = try seeded.requireID()
            let owner = try #require(try await User.query(on: app.db).filter(\.$email == "dev@example.com").first())
            let personal = try await app.makeUserToken(for: owner)

            try await app.testing().test(
                .PUT, APIPath.appVideo(ofApp: appID), headers: .bearer(personal),
                beforeRequest: { $0.body = .init(data: VideoFixture.make()) }
            ) { response in
                #expect(response.status == .ok)
                let dto = try? response.content.decode(AppDTO.self)
                #expect(dto?.videoURL?.hasPrefix("https://store.example.com/api/v1/apps/") == true)
            }
            let key = try #require(try await App.find(appID, on: app.db)?.videoKey)

            try await app.testing().test(
                .PUT, APIPath.appVideo(ofApp: appID), headers: .bearer(personal),
                beforeRequest: { $0.body = .init(data: VideoFixture.make(seconds: 90)) }
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("동영상이 60초를 넘습니다"))
            }

            try await app.testing().test(.DELETE, APIPath.appVideo(ofApp: appID), headers: .bearer(personal)) { response in
                #expect(response.status == .ok)
                let dto = try? response.content.decode(AppDTO.self)
                #expect(dto != nil && dto?.videoURL == nil)
            }
            #expect(try await storage.head(key: key) == nil)
            try await app.testing().test(.DELETE, APIPath.appVideo(ofApp: appID), headers: .bearer(personal)) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test("올릴 권한이 없는 사람은 못 올린다")
    func needsUploadAccess() async throws {
        try await withMigratedApp { app in
            let (seeded, _, _) = try await seed(app)
            let appID = try seeded.requireID()
            let (_, other) = try await app.makeUser(email: "other@example.com", role: .developer)
            #expect(try await upload(VideoFixture.make(), to: appID, token: other, on: app).0 == .forbidden)
        }
    }

    @Test("앱 상세와 고치는 화면에 동영상이 보인다")
    func pagesShowVideo() async throws {
        try await withMigratedApp { app in
            let (seeded, token, _) = try await seed(app)
            let appID = try seeded.requireID()
            try await app.testing().test(.GET, "/apps/\(appID.uuidString)/edit", headers: .sessionCookie(token)) { response in
                #expect(response.body.string.contains("동영상을 끌어다 놓거나 여기를 눌러서 파일을 선택하세요"))
            }
            _ = try await upload(VideoFixture.make(), to: appID, token: token, on: app)
            for path in ["/apps/\(appID.uuidString)", "/apps/\(appID.uuidString)/edit"] {
                try await app.testing().test(.GET, path, headers: .sessionCookie(token)) { response in
                    #expect(response.body.string.contains("<video class=\"video-preview\" src=\"/api/v1/apps/"))
                }
            }
        }
    }

    @Test("사람 토큰으로 동영상 경로가 열려 있다")
    func personalTokenScope() {
        let path = "/api/v1/apps/\(UUID().uuidString)/video"
        #expect(UserTokenScope.allows(method: .GET, path: path))
        #expect(UserTokenScope.allows(method: .PUT, path: path))
        #expect(UserTokenScope.allows(method: .DELETE, path: path))
    }

    @Test("앱을 지우면 동영상 오브젝트도 지운다")
    func removalDeletesVideo() async throws {
        try await withMigratedApp { app in
            let (seeded, token, storage) = try await seed(app)
            let appID = try seeded.requireID()
            _ = try await upload(VideoFixture.make(), to: appID, token: token, on: app)
            let key = try #require(try await App.find(appID, on: app.db)?.videoKey)
            let fresh = try #require(try await App.find(appID, on: app.db))
            let owner = try #require(try await User.query(on: app.db).filter(\.$email == "dev@example.com").first())
            try await AppRemoval.remove(
                fresh, typedName: fresh.name, by: owner, storage: storage, on: app.db, logger: app.logger
            )
            #expect(try await storage.head(key: key) == nil)
        }
    }
}
