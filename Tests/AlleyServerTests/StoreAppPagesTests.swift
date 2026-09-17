import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("스토어 앱 화면")
struct StoreAppPagesTests {
    @Test("설정을 저장한다")
    func savesSettings() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/store-app/settings",
                headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        [
                            "appName": "우리 스토어",
                            "bundleID": "com.example.alley.store",
                            "urlScheme": "ourstore",
                            "minimumSystemVersion": "14.0",
                        ],
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .seeOther)
            }

            try await app.testing().test(
                .GET, "/admin/store-app", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("우리 스토어"))
                #expect(response.body.string.contains("com.example.alley.store"))
            }
        }
    }

    /// **여기서 막지 않으면 서명·공증까지 다 끝난 뒤에 드러난다.** 공백이 든 번들
    /// ID 로 서명된 앱은 LaunchServices 가 등록하지 못한다.
    @Test(
        "형식이 틀린 값은 거절한다",
        arguments: [
            ["bundleID": "com example store"],
            ["bundleID": "nodots"],
            ["urlScheme": "Our Store"],
            ["urlScheme": "9store"],
            ["minimumSystemVersion": "열넷"],
            ["appName": ""],
        ]
    )
    func rejectsMalformedValues(_ override: [String: String]) async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            var form = [
                "appName": "우리 스토어",
                "bundleID": "com.example.alley.store",
                "urlScheme": "ourstore",
                "minimumSystemVersion": "14.0",
            ]
            form.merge(override) { _, new in new }

            try await app.testing().test(
                .POST, "/admin/store-app/settings",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(form, as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// 베이스 번들이 없으면 빌드할 것이 없다. 버튼은 꺼져 있지만 요청이 직접 올 수 있다.
    @Test("베이스 번들 없이 빌드하려 하면 무엇이 없는지 말한다")
    func buildRequiresBaseBundle() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/store-app/build", headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("error="))
            }

            try await app.testing().test(
                .GET, "/admin/store-app", headers: .sessionCookie(token)
            ) { response in
                // 서버 이미지에 스토어 앱이 없는 배포다 (시험은 그 상태로 돈다).
                // 빌드할 것이 없다는 사실과 무엇을 하면 되는지를 함께 말해야 한다.
                #expect(response.body.string.contains("이 서버 이미지에 스토어 앱이 들어 있지 않습니다"))
            }
        }
    }

    @Test("zip 이 아닌 베이스 번들은 거절한다")
    func rejectsNonZipBaseBundle() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/store-app/base-bundle",
                headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        BaseBundleUpload(
                            version: "0.3.0",
                            bundle: File(data: "zip 이 아니다", filename: "bundle.zip")
                        ),
                        as: .formData
                    )
                }
            ) { response in
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("error="))
            }
        }
    }

    /// 빌드 경로 전체가 한 번에 지나가는지 본다. 설정 → 베이스 번들 → 아이콘 → 빌드 →
    /// 버전·아티팩트·서명 잡까지다.
    @Test("빌드하면 버전과 서명 잡이 생긴다")
    func buildProducesVersionAndJob() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            settings.bundleID = "com.example.alley.store"
            settings.appName = "우리 스토어"
            settings.urlScheme = "ourstore"
            try await settings.save(on: app.db)

            let storage = app.useFakeStorage()
            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )
            try await BrandingAssetService.accept(
                kind: .appIcon,
                data: PNGFixture.png(width: 1024, height: 1024),
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )

            try await app.testing().test(
                .POST, "/admin/store-app/build", headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("built="))
            }

            let versions = try await Version.query(on: app.db).all()
            #expect(versions.count == 1)
            let version = try #require(versions.first)
            #expect(version.shortVersion == "0.4.0")
            #expect(version.buildNumber == 1)
            // 서버가 올린 것이라 업로드 통지를 기다릴 이유가 없다. 바로 uploaded 다.
            #expect(version.state == .uploaded)

            let jobs = try await SigningJob.query(on: app.db).all()
            #expect(jobs.count == 1)

            // 조립 결과가 스토리지에 실제로 놓였고, 그 안에 우리 값이 들어 있는가.
            let artifact = try #require(try await Artifact.query(on: app.db).first())
            let stored = try await storage.get(key: artifact.storageKey, limit: 64 * 1024 * 1024)
            let entries = try ZipArchive.entries(in: stored)
            #expect(entries.contains { $0.name == "우리 스토어.app/Contents/Resources/AppIcon.icns" })

            let plist = try #require(entries.first { $0.name.hasSuffix("Info.plist") })
            let text = String(decoding: plist.compressedData, as: UTF8.self)
            #expect(text.contains("com.example.alley.store"))
            #expect(text.contains("<string>ourstore</string>"))
        }
    }

    /// **이슈 #18 이 여기서 막힌다.** 예전에는 번들의 CFBundleVersion 을 셸이,
    /// 스토어의 빌드 번호를 CLI 가 따로 정해서 두 번째 릴리스부터 "업데이트 있음" 이
    /// 풀리지 않았다. 이제 정하는 곳이 하나다.
    @Test("두 번 빌드하면 빌드 번호가 오르고 번들도 같은 값을 갖는다")
    func buildNumberMatchesBundle() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            settings.bundleID = "com.example.alley.store"
            settings.appName = "우리 스토어"
            try await settings.save(on: app.db)

            let storage = app.useFakeStorage()
            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )

            for _ in 0..<2 {
                try await app.testing().test(
                    .POST, "/admin/store-app/build", headers: .form(cookie: token)
                ) { #expect($0.status == .seeOther) }
            }

            let versions = try await Version.query(on: app.db)
                .sort(\.$buildNumber, .ascending)
                .all()
            #expect(versions.map(\.buildNumber) == [1, 2])

            // 스토어가 아는 번호와 번들 안의 값이 같은가. 이것이 어긋나면 설치된 앱이
            // 자기를 최신이라고 말한다.
            for version in versions {
                let artifact = try #require(
                    try await Artifact.query(on: app.db)
                        .filter(\.$version.$id == version.requireID())
                        .first()
                )
                let stored = try await storage.get(
                    key: artifact.storageKey, limit: 64 * 1024 * 1024
                )
                let plist = try #require(
                    try ZipArchive.entries(in: stored).first { $0.name.hasSuffix("Info.plist") }
                )
                let text = String(decoding: plist.compressedData, as: UTF8.self)
                #expect(text.contains("<key>CFBundleVersion</key>"))
                #expect(text.contains("<string>\(version.buildNumber)</string>"))
            }
        }
    }

    /// 번들 ID 를 바꾸면 이미 깔린 앱은 업데이트 대상이 아니라 별개 앱이 된다.
    /// 그 사실을 읽고 한 번 더 말하게 한다.
    @Test("내보낸 뒤에는 확인 없이 번들 ID 를 못 바꾼다")
    func locksIdentityAfterShipping() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            settings.bundleID = "com.example.alley.store"
            settings.appName = "우리 스토어"
            try await settings.save(on: app.db)

            let storage = app.useFakeStorage()
            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )
            try await app.testing().test(
                .POST, "/admin/store-app/build", headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            let changed = [
                "appName": "우리 스토어",
                "bundleID": "com.example.alley.newstore",
                "urlScheme": "ourstore",
                "minimumSystemVersion": "14.0",
            ]

            try await app.testing().test(
                .POST, "/admin/store-app/settings",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(changed, as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("업데이트를 받지 못하고"))
            }

            // 확인을 켜면 바꿀 수 있다. 막는 것이 목적이 아니라 알고 하게 하는 것이다.
            var confirmed = changed
            confirmed["confirmIdentityChange"] = "on"
            try await app.testing().test(
                .POST, "/admin/store-app/settings",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(confirmed, as: .urlEncodedForm) }
            ) { #expect($0.status == .seeOther) }

            let reloaded = try #require(
                try await StoreAppSettings.find(StoreAppSettings.singletonID, on: app.db)
            )
            #expect(reloaded.bundleID == "com.example.alley.newstore")
        }
    }

    /// **확인 체크박스가 실제로 칸을 풀 수 있어야 한다.**
    ///
    /// 예전에는 서버가 `readonly` 를 박아 내보냈다. 그것을 풀어주는 쪽이 없어서
    /// 확인을 켜도 칸이 잠긴 채였고, 바꿀 수 있는 것이 없으니 확인할 것도 없었다.
    /// 체크박스는 눌러도 아무 일이 없는 장식이었고, 그 사실은 화면을 눌러봐야만
    /// 드러난다.
    ///
    /// 잠그는 것은 이제 `Public/lock-fields.js` 다. 서버가 다시 `readonly` 를
    /// 박으면 같은 일이 되풀이되므로 여기서 걸어둔다.
    @Test("잠긴 칸을 확인으로 풀 수 있게 내보낸다")
    func lockedFieldsCanBeUnlocked() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            settings.bundleID = "com.example.alley.store"
            settings.appName = "우리 스토어"
            try await settings.save(on: app.db)

            let storage = app.useFakeStorage()
            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )
            try await app.testing().test(
                .POST, "/admin/store-app/build", headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            try await app.testing().test(
                .GET, "/admin/store-app", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                let fields = body.components(separatedBy: #"data-lock-group="identity""#).count - 1
                #expect(fields == 2, "번들 ID 와 URL 스킴 둘 다 잠금 대상이어야 합니다.")
                #expect(body.contains(#"data-unlocks="identity""#), "확인이 칸과 이어져 있지 않습니다.")

                // 서버가 잠그면 스크립트가 풀 수 없다. 잠금은 스크립트 몫이다.
                let inputs = body.components(separatedBy: "<input").filter {
                    $0.contains(#"name="bundleID""#) || $0.contains(#"name="urlScheme""#)
                }
                for input in inputs {
                    let tag = input.prefix(while: { $0 != ">" })
                    #expect(!tag.contains("readonly"), "서버가 칸을 잠그면 확인이 장식이 됩니다.")
                }
            }
        }
    }

    /// 올리는 길만 있고 무르는 길이 없으면 잘못 올린 번들을 데이터베이스에서 손으로
    /// 지워야 한다. 비운 뒤에는 이 서버에 들어 있는 것으로 돌아간다 (ADR-0048).
    @Test("올려둔 번들을 비우면 설정도 오브젝트도 남지 않는다")
    func removesUploadedBaseBundle() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            let storage = app.useFakeStorage()
            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )
            let key = try #require(settings.baseBundleKey)

            try await app.testing().test(
                .POST, "/admin/store-app/base-bundle/remove", headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(!location.contains("error="))
            }

            let stored = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            #expect(stored.baseBundleKey == nil)
            #expect(stored.baseBundleVersion == nil)
            #expect(stored.baseBundleSize == nil)
            #expect(stored.baseBundleUploadedAt == nil)
            // 오브젝트를 남기면 아무도 가리키지 않는 번들이 스토리지에 쌓인다.
            #expect(try await storage.head(key: key) == nil)
        }
    }

    @Test("비울 것이 없으면 눌러도 그 자리에 선다")
    func removingNothingIsHarmless() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = app.useFakeStorage()

            try await app.testing().test(
                .POST, "/admin/store-app/base-bundle/remove", headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(!location.contains("error="))
            }
        }
    }

    @Test("올려둔 번들이 있을 때만 비우기 버튼이 보인다")
    func showsRemoveButtonOnlyForUploadedBundle() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            let storage = app.useFakeStorage()

            try await app.testing().test(
                .GET, "/admin/store-app", headers: .sessionCookie(token)
            ) { response in
                #expect(!response.body.string.contains("올려둔 번들 비우기"))
            }

            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )

            try await app.testing().test(
                .GET, "/admin/store-app", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains("올려둔 번들 비우기"))
                // 시험은 이미지에 스토어 앱이 없는 배포로 돈다. 그 상태에서 비우면
                // 빌드할 것이 남지 않는다는 사실을 누르기 전에 말해야 한다.
                #expect(body.contains("비우면 빌드할 것이 남지 않습니다"))
            }
        }
    }

    struct BaseBundleUpload: Content {
        var version: String
        var bundle: File
    }
}
