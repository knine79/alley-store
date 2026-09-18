import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 포털에 App ID 를 만들 자리를 어디에 둘지 (ADR-0005, ADR-0053).
///
/// 앱을 만드는 화면에는 둘 수 없다. 프로필이 필요한지는 entitlements 를 봐야 아는데
/// 그것은 버전을 올릴 때 들어온다. 그래서 앱 상세에, 그 권한이 실제로 보인 뒤에 둔다.
@Suite("앱의 포털 App ID")
struct PortalAppIDTests {
    /// 프로필이 필요한 권한. `com.apple.developer.` 로 시작한다.
    private let cloudKit = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array></dict>
        </plist>
        """

    /// 프로필 없이도 서명되는 권한. 하드닝 쪽이다.
    private let jitOnly = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>com.apple.security.cs.allow-jit</key><true/></dict>
        </plist>
        """

    private func seed(
        on app: Application, entitlements: String?
    ) async throws -> (appID: UUID, cookie: String) {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(
            bundleID: "com.example.tool", name: "도구", owner: owner
        )
        let appID = try record.requireID()
        let version = try await app.seedVersion(
            appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
        )
        version.entitlements = entitlements
        try await version.save(on: app.db)
        return (appID, token)
    }

    @Test("프로필이 필요한 권한을 쓰면 App ID 자리가 나온다")
    func showsForProfileEntitlements() async throws {
        try await withMigratedApp { app in
            let (appID, cookie) = try await seed(on: app, entitlements: cloudKit)

            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(cookie)
            ) { response in
                let body = response.body.string
                #expect(body.contains("Apple App ID"))
                // 왜 필요한지 근거가 화면에 있어야 한다. 그냥 "등록하세요" 는 판단을 못 돕는다.
                #expect(body.contains("com.apple.developer.icloud-services"))
            }
        }
    }

    @Test("하드닝 권한만 쓰면 나오지 않는다")
    func hidesForSandboxOnlyEntitlements() async throws {
        try await withMigratedApp { app in
            let (appID, cookie) = try await seed(on: app, entitlements: jitOnly)

            // 대부분의 맥 앱이 여기 해당한다. 포털에 등록할 것이 없다.
            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(cookie)
            ) { #expect(!$0.body.string.contains("Apple App ID")) }
        }
    }

    @Test("entitlements 를 안 올렸으면 나오지 않는다")
    func hidesWithoutEntitlements() async throws {
        try await withMigratedApp { app in
            let (appID, cookie) = try await seed(on: app, entitlements: nil)

            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(cookie)
            ) { #expect(!$0.body.string.contains("Apple App ID")) }
        }
    }

    @Test("연동이 없으면 버튼 대신 무엇이 빠졌는지 말한다")
    func explainsMissingIntegration() async throws {
        try await withMigratedApp { app in
            let (appID, cookie) = try await seed(on: app, entitlements: cloudKit)

            // 시험 환경에는 App Store Connect 설정이 없다. 눌러도 안 되는 버튼을
            // 그리는 대신 어디를 채워야 하는지 알려준다.
            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(cookie)
            ) { response in
                let body = response.body.string
                #expect(body.contains("Apple App ID"))
                #expect(!body.contains("App ID 만들기"))
                #expect(body.contains("App Store Connect 연동이 설정되지 않아"))
            }
        }
    }

    @Test("연동이 없으면 만들기 요청도 막힌다")
    func rejectsRegistrationWithoutIntegration() async throws {
        try await withMigratedApp { app in
            let (appID, cookie) = try await seed(on: app, entitlements: cloudKit)

            try await app.testing().test(
                .POST, "/apps/\(appID)/portal-app-id", headers: .form(cookie: cookie)
            ) { #expect($0.status == .serviceUnavailable) }
        }
    }

    @Test("남의 앱에는 만들 수 없다")
    func requiresManageAccess() async throws {
        try await withMigratedApp { app in
            let (appID, _) = try await seed(on: app, entitlements: cloudKit)
            let (_, other) = try await app.makeUser(email: "other@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/apps/\(appID)/portal-app-id", headers: .form(cookie: other)
            ) { #expect($0.status == .forbidden) }
        }
    }
}

/// 와일드카드는 앱 등록 규칙과 같은 접두사에서 나와야 한다 (ADR-0005).
@Suite("와일드카드 App ID")
struct WildcardBundleIDTests {
    @Test("접두사가 없으면 만들지 않고 이유를 말한다")
    func requiresPrefix() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )
            settings.bundleIDPrefix = nil
            try await settings.save(on: app.db)

            try await app.testing().test(
                .POST, "/admin/portal/bundle-ids", headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("번들 ID 접두사가 비어 있습니다"))
            }
        }
    }

    @Test("관리자가 아니면 만들 수 없다")
    func requiresAdmin() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/admin/portal/bundle-ids", headers: .form(cookie: token)
            ) { #expect($0.status == .forbidden) }
        }
    }
}

@Suite("프로필이 필요한 권한 판정")
struct ProvisioningProfileEntitlementTests {
    @Test(
        "com.apple.developer 로 시작하는 것만 프로필을 요구한다",
        arguments: [
            ("com.apple.developer.icloud-services", true),
            ("com.apple.developer.aps-environment", true),
            ("com.apple.security.cs.allow-jit", false),
            ("com.apple.security.app-sandbox", false),
        ]
    )
    func classifies(_ key: String, _ expected: Bool) throws {
        #expect(EntitlementsPlist.requiresProvisioningProfile(key) == expected)
    }

    @Test("섞여 있으면 프로필이 필요한 것만 추린다")
    func filtersMixedKeys() throws {
        let keys = [
            "com.apple.security.cs.allow-jit",
            "com.apple.developer.team-identifier",
            "com.apple.security.app-sandbox",
            "com.apple.developer.associated-domains",
        ]

        #expect(
            EntitlementsPlist.requiringProvisioningProfile(in: keys) == [
                "com.apple.developer.associated-domains",
                "com.apple.developer.team-identifier",
            ]
        )
    }
}
