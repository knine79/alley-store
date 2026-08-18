import AlleyShared
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("설정 로딩")
struct AppConfigTests {
    @Test("필수 항목이 모두 있으면 로딩된다")
    func loadsWithRequiredKeys() throws {
        let config = try AppConfig.load(from: TestSupport.minimalEnvironment)
        #expect(!config.database.url.isEmpty)
        #expect(config.storage.bucket == "alley-artifacts")
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
        var environment = TestSupport.minimalEnvironment
        environment["ALLOWED_EMAIL_DOMAINS"] = " Example.com, sub.Example.COM ,"

        let config = try AppConfig.load(from: environment)
        #expect(config.store.allowedEmailDomains == ["example.com", "sub.example.com"])
    }

    @Test("도메인 목록이 없으면 빈 배열이 된다")
    func defaultsToEmptyDomainList() throws {
        let config = try AppConfig.load(from: TestSupport.minimalEnvironment)
        #expect(config.store.allowedEmailDomains.isEmpty)
    }

    @Test("잘못된 정수 설정을 거부한다")
    func rejectsInvalidInteger() {
        var environment = TestSupport.minimalEnvironment
        environment["SESSION_TTL"] = "-1"

        #expect(throws: AppConfig.LoadError.self) {
            try AppConfig.load(from: environment)
        }
    }

    @Test("불리언 설정을 여러 표기로 받는다", arguments: [
        ("true", true), ("1", true), ("yes", true), ("on", true),
        ("false", false), ("0", false), ("no", false),
    ])
    func parsesBooleanForms(_ raw: String, _ expected: Bool) throws {
        var environment = TestSupport.minimalEnvironment
        environment["ENFORCE_BUNDLE_ID_PREFIX"] = raw

        let config = try AppConfig.load(from: environment)
        #expect(config.store.enforceBundleIDPrefix == expected)
    }

    @Test("메타 정보에 비밀값이 섞이지 않는다")
    func storeMetaExcludesSecrets() throws {
        var environment = TestSupport.minimalEnvironment
        environment["STORE_NAME"] = "Example Store"
        environment["ALLOWED_EMAIL_DOMAINS"] = "example.com"

        let config = try AppConfig.load(from: environment)
        let meta = config.storeMeta

        #expect(meta.storeName == "Example Store")
        #expect(meta.allowedEmailDomains == ["example.com"])

        // 메타를 직렬화한 결과에 비밀값이 들어가면 안 된다.
        let encoded = try JSONEncoder().encode(meta)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("client-secret"))
        #expect(!json.contains("test-secret"))
        #expect(!json.contains("secret"))
    }
}

@Suite("부트스트랩 엔드포인트")
struct MetaEndpointTests {
    @Test("헬스체크가 응답한다")
    func healthResponds() async throws {
        try await withConfiguredApp { app in
            try await app.testing().test(.GET, APIPath.health) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(HealthResponse.self)
                #expect(body.status == "ok")
                #expect(body.apiVersion == APIPath.currentAPIVersion)
            }
        }
    }

    @Test("메타 엔드포인트가 브랜딩을 그대로 내려준다")
    func metaReturnsConfiguredBranding() async throws {
        try await withConfiguredApp(overrides: [
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
        }
    }

    @Test("메타 엔드포인트는 인증 없이 열려 있다")
    func metaRequiresNoAuthentication() async throws {
        try await withConfiguredApp { app in
            // 인증 헤더 없이 호출해도 200이어야 클라이언트가 부트스트랩할 수 있다.
            try await app.testing().test(.GET, APIPath.meta) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
