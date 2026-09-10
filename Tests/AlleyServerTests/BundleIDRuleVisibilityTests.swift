import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 번들 ID 규칙을 화면이 실제로 말해주는가.
///
/// dmg 는 올리기 전에 열어볼 수 없어서 규칙 위반을 업로드가 끝난 뒤에야 안다
/// (ADR-0034). 그러면 최소한 **무엇을 만족해야 하는지는** 미리 알려줘야 한다.
/// "이 스토어의 규칙에 맞아야 합니다" 만 쓰면 알려주는 것이 아니다.
@Suite("번들 ID 규칙 노출")
struct BundleIDRuleVisibilityTests {
    private func seedSettings(
        on app: Application,
        prefix: String?,
        enforce: Bool
    ) async throws {
        let settings = StoreSettings(
            storeName: "Example Store",
            bundleIDPrefix: prefix,
            enforceBundleIDPrefix: enforce
        )
        try await settings.save(on: app.db)
    }

    @Test("등록 화면이 접두어를 그대로 보여준다")
    func registrationShowsPrefix() async throws {
        try await withMigratedApp { app in
            try await seedSettings(on: app, prefix: "com.example", enforce: true)
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                // dmg 안내 두 자리(고르기 전, 고른 뒤) 모두에 규칙이 있어야 한다.
                #expect(body.components(separatedBy: "com.example.").count - 1 >= 2)
                #expect(body.contains("시작하지 않으면 그때 실패합니다"))
            }
        }
    }

    @Test("올리기 전 팝업이 규칙과 버튼 둘을 갖춘다")
    func dialogCarriesRuleAndButtons() async throws {
        try await withMigratedApp { app in
            try await seedSettings(on: app, prefix: "com.example", enforce: true)
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains(#"<dialog class="modal" id="dmg-dialog""#))
                #expect(body.contains("업로드가 완료된 후에 번들 ID 와 앱 정보를 읽을 수 있습니다"))
                #expect(body.contains("다시 빌드해서 올려주세요"))
                #expect(body.contains(#"value="upload""#))
                #expect(body.contains(#"value="cancel""#))

                // 취소가 먼저 와야 Enter 로 닫았을 때 올라가지 않는다.
                let cancel = try #require(body.range(of: #"value="cancel""#))
                let upload = try #require(body.range(of: #"value="upload""#))
                #expect(cancel.lowerBound < upload.lowerBound)
            }
        }
    }

    /// 강제하지 않는 스토어에서 "실패합니다" 라고 하면 거짓말이다.
    @Test("강제하지 않으면 실패한다고 말하지 않는다")
    func silentWhenNotEnforced() async throws {
        try await withMigratedApp { app in
            try await seedSettings(on: app, prefix: "com.example", enforce: false)
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(!body.contains("시작하지 않으면 그때 실패합니다"))
                // 팝업은 그대로 뜬다. 올린 뒤에야 정보를 안다는 사실은 정책과
                // 무관하게 사실이다. 다만 규칙 문장만 빠진다.
                #expect(body.contains("dmg-dialog"))
                #expect(!body.contains("다시 빌드해서 올려주세요"))
            }
        }
    }

    @Test("확인 화면도 확정 전이면 규칙을 말한다")
    func confirmScreenShowsRule() async throws {
        try await withMigratedApp { app in
            try await seedSettings(on: app, prefix: "com.example", enforce: true)
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            let record = try await app.seedApp(
                bundleID: AppRegistration.provisionalBundleID(), name: "확인 중", owner: owner
            )
            record.bundleIDPending = true
            try await record.save(on: app.db)
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            let versionID = try version.requireID()

            try await app.testing().test(
                .GET,
                "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/confirm",
                headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains("com.example."))
                #expect(body.contains("시작해야 합니다"))
            }
        }
    }

    /// 앱을 올리는 사람은 서명 워커가 무엇인지 모른다. 그 말이 화면에 나오면
    /// 자기가 뭘 모르는지부터 찾게 된다.
    @Test("등록 흐름에 워커라는 말이 나오지 않는다")
    func noWorkerJargon() async throws {
        try await withMigratedApp { app in
            try await seedSettings(on: app, prefix: "com.example", enforce: true)
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            let record = try await app.seedApp(
                bundleID: AppRegistration.provisionalBundleID(), name: "확인 중", owner: owner
            )
            record.bundleIDPending = true
            try await record.save(on: app.db)
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            let versionID = try version.requireID()

            let paths = [
                "/apps",
                "/apps/new",
                "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/confirm",
            ]
            for path in paths {
                try await app.testing().test(
                    .GET, path, headers: .sessionCookie(token)
                ) { response in
                    // HTML 주석은 템플릿을 고치는 사람에게 남긴 것이라 그대로 둔다.
                    // 화면에 보이는 글자만 본다.
                    let visible = response.body.string.replacingOccurrences(
                        of: "(?s)<!--.*?-->", with: "", options: .regularExpression
                    )
                    #expect(!visible.contains("워커"), "\(path) 에 워커가 나온다")
                }
            }
        }
    }
}
