import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("설정 로딩")
struct AppConfigTests {
    @Test("필수 항목이 모두 있으면 로딩된다")
    func loadsWithRequiredKeys() throws {
        let config = try TestSupport.config()
        #expect(config.storage.bucket == "alley-artifacts")
        #expect(!config.database.url.isEmpty)
    }

    @Test("필수 항목이 빠지면 어떤 키인지 알려준다", arguments: [
        "DATABASE_URL", "S3_BUCKET", "GOOGLE_CLIENT_ID", "JWT_SECRET", "PUBLIC_BASE_URL",
    ])
    func reportsMissingKey(_ key: String) {
        var environment = TestSupport.minimalEnvironment
        environment.removeValue(forKey: key)

        #expect(throws: AppConfig.LoadError.self) {
            try AppConfig.load(from: environment)
        }
    }

    @Test("빈 문자열은 값이 없는 것으로 본다")
    func treatsEmptyStringAsMissing() {
        var environment = TestSupport.minimalEnvironment
        environment["JWT_SECRET"] = ""

        #expect(throws: AppConfig.LoadError.self) {
            try AppConfig.load(from: environment)
        }
    }

    @Test("쉼표로 구분한 도메인 목록을 파싱하고 소문자로 맞춘다")
    func parsesDomainList() throws {
        let config = try TestSupport.config(overrides: [
            "ALLOWED_EMAIL_DOMAINS": " Example.com, sub.Example.COM ,"
        ])
        #expect(config.store.seed.allowedEmailDomains == ["example.com", "sub.example.com"])
    }

    @Test("도메인 목록이 없으면 빈 배열이 된다")
    func defaultsToEmptyDomainList() throws {
        #expect(try TestSupport.config().store.seed.allowedEmailDomains.isEmpty)
    }

    @Test("잘못된 정수 설정을 거부한다")
    func rejectsInvalidInteger() {
        #expect(throws: AppConfig.LoadError.self) {
            try TestSupport.config(overrides: ["SESSION_TTL": "-1"])
        }
    }

    @Test("불리언 설정을 여러 표기로 받는다", arguments: [
        ("true", true), ("1", true), ("yes", true), ("on", true),
        ("false", false), ("0", false), ("no", false),
    ])
    func parsesBooleanForms(_ raw: String, _ expected: Bool) throws {
        let config = try TestSupport.config(overrides: ["ENFORCE_BUNDLE_ID_PREFIX": raw])
        #expect(config.store.seed.enforceBundleIDPrefix == expected)
    }

    @Test("커스텀 URL 스킴은 설정이 아니라 환경변수에서만 온다")
    func callbackSchemeStaysInEnvironment() throws {
        // 스토어 앱의 Info.plist 에 박히는 값이라 관리자 화면에서 바꾸면 안 된다.
        let config = try TestSupport.config(overrides: ["STORE_APP_URL_SCHEME": "examplestore"])
        #expect(config.store.callbackURLScheme == "examplestore")
    }
}

@Suite("스토어 메타 변환")
struct StoreMetaConversionTests {
    @Test("설정을 메타로 옮길 때 노출할 항목만 간다")
    func metaCarriesOnlyPublicFields() throws {
        let settings = StoreSettings(
            storeName: "Example Store",
            logoURL: "https://example.com/logo.png",
            accentColor: "#FF8800",
            allowedEmailDomains: ["example.com"],
            bundleIDPrefix: "com.example",
            enforceBundleIDPrefix: true
        )

        let meta = settings.toMeta(callbackURLScheme: "examplestore")
        #expect(meta.storeName == "Example Store")
        #expect(meta.accentColor == "#FF8800")
        #expect(meta.allowedEmailDomains == ["example.com"])
        #expect(meta.callbackURLScheme == "examplestore")

        // 번들 ID 정책은 밖에 알릴 이유가 없다. 관리자만 본다.
        let json = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self)
        #expect(!json.contains("com.example"))
        #expect(!json.contains("enforce"))
    }
}

@Suite("부트스트랩 엔드포인트")
struct MetaEndpointTests {
    @Test("헬스체크는 데이터베이스 없이도 응답한다")
    func healthRespondsWithoutDatabase() async throws {
        // 오케스트레이터가 찌르는 경로다. 데이터베이스가 죽었을 때도 프로세스가
        // 살아 있다는 것은 알려줘야 한다.
        try await withConfiguredApp { app in
            try await app.testing().test(.GET, APIPath.health) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(HealthResponse.self)
                #expect(body.status == "ok")
                #expect(body.apiVersion == APIPath.currentAPIVersion)
            }
        }
    }

    @Test("메타 엔드포인트가 환경변수 초기값을 씨앗으로 심는다")
    func metaSeedsFromEnvironmentOnFirstAccess() async throws {
        try await withMigratedApp(overrides: [
            "STORE_NAME": "Example Store",
            "STORE_ACCENT_COLOR": "#FF8800",
            "ALLOWED_EMAIL_DOMAINS": "example.com",
            "STORE_APP_URL_SCHEME": "examplestore",
        ]) { app in
            try await app.testing().test(.GET, APIPath.meta) { response in
                #expect(response.status == .ok)
                let meta = try response.content.decode(StoreMeta.self)
                #expect(meta.storeName == "Example Store")
                #expect(meta.accentColor == "#FF8800")
                #expect(meta.allowedEmailDomains == ["example.com"])
                #expect(meta.callbackURLScheme == "examplestore")
                #expect(meta.apiVersion == APIPath.currentAPIVersion)
            }

            // 씨앗은 한 번만 심긴다. 행이 실제로 생겼는지 확인한다.
            let stored = try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            #expect(stored?.storeName == "Example Store")
        }
    }

    @Test("씨앗을 심은 뒤에는 환경변수를 무시하고 데이터베이스를 따른다")
    func databaseWinsOverEnvironmentAfterSeeding() async throws {
        try await withMigratedApp(overrides: ["STORE_NAME": "Example Store"]) { app in
            // 관리자가 화면에서 이름을 바꾼 상황을 만든다.
            let settings = try await StoreSettings.loadOrSeed(
                on: app.db,
                seed: app.alleyConfig.store.seed,
                logger: app.logger
            )
            settings.storeName = "Renamed Store"
            try await settings.save(on: app.db)

            // 환경변수는 그대로 "Example Store" 지만 데이터베이스가 이긴다.
            // 그러지 않으면 화면에서 바꾼 값이 재시작마다 되돌아간다.
            try await app.testing().test(.GET, APIPath.meta) { response in
                let meta = try response.content.decode(StoreMeta.self)
                #expect(meta.storeName == "Renamed Store")
            }
        }
    }

    @Test("메타 엔드포인트는 인증 없이 열려 있고 비밀값을 담지 않는다")
    func metaIsPublicAndCarriesNoSecrets() async throws {
        try await withMigratedApp(overrides: ["STORE_NAME": "Example Store"]) { app in
            // 스토어 앱이 로그인 전에 부트스트랩해야 하므로 열려 있어야 한다.
            try await app.testing().test(.GET, APIPath.meta) { response in
                #expect(response.status == .ok)

                let json = response.body.string
                #expect(!json.contains("client-secret"))
                #expect(!json.contains("test-secret"))
                #expect(!json.contains("secret"))
            }
        }
    }
}
