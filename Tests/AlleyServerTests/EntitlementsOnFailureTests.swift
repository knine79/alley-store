import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// entitlements 를 언제 묻는가.
///
/// 대부분의 맥 앱은 필요 없다. 그래서 올릴 때는 묻지 않고, 번들을 열어보고 정말
/// 없으면 안 되는 것을 확인한 뒤에 그 자리에서 받는다 (ADR-0036).
@Suite("entitlements 는 필요할 때만 묻는다")
struct EntitlementsOnFailureTests {
    /// 실패한 버전 하나와 그 실패 갈래를 남긴 잡.
    private func seedFailure(
        on app: Application,
        owner: User,
        code: SigningFailureCode
    ) async throws -> (appID: UUID, versionID: UUID) {
        let record = try await app.seedApp(
            bundleID: "com.example.electron", name: "전자앱", owner: owner
        )
        let appID = try record.requireID()
        let version = try await app.seedVersion(
            appID: appID, short: "1.0.0", build: 1, state: .failed, by: owner
        )
        let versionID = try version.requireID()

        let job = SigningJob(versionID: versionID)
        job.state = .failed
        job.failureCode = code
        job.failureReason = "권한이 모자랍니다."
        try await job.save(on: app.db)

        return (appID, versionID)
    }

    // MARK: - 올릴 때는 묻지 않는다

    @Test("새 앱 등록 화면에 entitlements 칸이 없다")
    func registrationDoesNotAsk() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { response in
                #expect(!response.body.string.contains(#"name="entitlements""#))
            }
        }
    }

    @Test("버전 업로드 화면에도 없다")
    func versionUploadDoesNotAsk() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.app", name: "앱", owner: owner
            )
            let appID = try record.requireID().uuidString

            try await app.testing().test(
                .GET, "/apps/\(appID)/versions/new", headers: .sessionCookie(token)
            ) { response in
                #expect(!response.body.string.contains(#"name="entitlements""#))
            }
        }
    }

    // MARK: - 필요하면 그 자리에서 받는다

    @Test("권한 때문에 실패하면 붙일 자리가 생긴다")
    func failureOffersAttachment() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await seedFailure(on: app, owner: owner, code: .entitlementsRejected)

            try await app.testing().test(
                .GET, "/apps/\(seeded.appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains(#"name="entitlements""#))
                #expect(body.contains("붙여서 다시 시도"))
                // 그냥 다시 시도하면 똑같이 실패한다. 버튼이 둘이면 안 된다.
                #expect(!body.contains(">다시 시도<"))
            }
        }
    }

    /// 그 파일이 아예 없는 사람이 실제로 온다. 애드혹 서명으로 개발하던 앱에는
    /// entitlements 를 만들 이유가 없었고, 그런 앱이 올라온다. 키 이름 하나만
    /// 알려주면 XML 뼈대부터 막힌다.
    @Test("붙일 파일이 없는 사람에게 본보기를 준다")
    func failureCarriesTemplate() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await seedFailure(on: app, owner: owner, code: .entitlementsRejected)

            try await app.testing().test(
                .GET, "/apps/\(seeded.appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains(EntitlementsGuidance.jitKey))
                #expect(body.contains("com.apple.security.cs.disable-library-validation"))
                // XML 은 이스케이프되어 나가야 한다. 날것으로 나가면 페이지가 깨진다.
                #expect(body.contains("&lt;plist"))
                #expect(!body.contains("<plist"))
            }
        }
    }

    /// ADR-0036 이 새 버전 화면의 파일 칸을 없앴다. 안내가 계속 그 칸을 가리키면
    /// 실패한 사람이 없는 것을 찾으러 간다. 붙일 자리는 그 실패 바로 아래에 있다.
    @Test("안내가 없어진 새 버전 화면 칸을 가리키지 않는다")
    func adviceDoesNotPointAtRemovedField() {
        let advice = SigningFailureGuidance.whatToDo(.entitlementsRejected)
        #expect(!advice.contains("새 버전 화면"))
        #expect(advice.contains("붙여서 다시 시도"))
    }

    /// 인증서 만료처럼 파일과 상관없는 실패에는 칸이 나오지 않는다. 올린 사람이
    /// 할 수 있는 일이 없는데 파일을 달라고 하면 헤매게 된다.
    @Test("다른 이유로 실패하면 그냥 다시 시도한다")
    func otherFailuresJustRetry() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await seedFailure(
                on: app, owner: owner, code: .signingIdentityUnavailable
            )

            try await app.testing().test(
                .GET, "/apps/\(seeded.appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains(">다시 시도<"))
                #expect(!body.contains(#"name="entitlements""#))
            }
        }
    }

    // MARK: - 붙인 것이 저장된다

    @Test("붙여서 다시 시도하면 그 plist 로 서명한다")
    func retryStoresAttachedEntitlements() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await seedFailure(on: app, owner: owner, code: .entitlementsRejected)

            let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict><key>com.apple.security.cs.allow-jit</key><true/></dict>
                </plist>
                """
            let boundary = "alleyboundary"
            var headers = HTTPHeaders.sessionCookie(token)
            headers.add(name: .origin, value: "http://localhost:8080")
            headers.replaceOrAdd(name: .host, value: "localhost:8080")
            headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data",
                parameters: ["boundary": boundary]
            )
            let body = """
                --\(boundary)\r
                Content-Disposition: form-data; name="entitlements"; filename="app.entitlements"\r
                Content-Type: application/xml\r
                \r
                \(plist)\r
                --\(boundary)--\r

                """

            try await app.testing().test(
                .POST,
                "/apps/\(seeded.appID.uuidString)/versions/\(seeded.versionID.uuidString)/retry",
                headers: headers,
                body: ByteBuffer(string: body)
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(try await Version.find(seeded.versionID, on: app.db))
            #expect(stored.state == .uploaded)
            #expect(stored.entitlements?.contains("allow-jit") == true)
            #expect(try await SigningJob.query(on: app.db)
                .filter(\.$state == .queued).count() == 1)
        }
    }

    /// 파일 없이 오는 재시도가 예전 그대로 돌아야 한다. 여기가 깨지면 인증서를
    /// 갱신하고 다시 시도하는 흔한 경로가 막힌다.
    @Test("파일 없는 재시도는 원래 값을 그대로 둔다")
    func plainRetryKeepsExisting() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await seedFailure(
                on: app, owner: owner, code: .signingIdentityUnavailable
            )
            let version = try #require(try await Version.find(seeded.versionID, on: app.db))
            version.entitlements = "<plist version=\"1.0\"><dict/></plist>"
            try await version.save(on: app.db)

            try await app.testing().test(
                .POST,
                "/apps/\(seeded.appID.uuidString)/versions/\(seeded.versionID.uuidString)/retry",
                headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(try await Version.find(seeded.versionID, on: app.db))
            #expect(stored.state == .uploaded)
            #expect(stored.entitlements != nil)
        }
    }
}
