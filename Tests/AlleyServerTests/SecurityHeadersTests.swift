import AlleyShared
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("보안 헤더")
struct SecurityHeadersTests {
    /// 응답 하나에서 CSP 지시문을 뽑아 이름으로 찾을 수 있게 만든다.
    private func directives(_ response: TestingHTTPResponse) -> [String: String] {
        guard let policy = response.headers.first(name: "Content-Security-Policy") else {
            return [:]
        }
        var found: [String: String] = [:]
        for part in policy.split(separator: ";") {
            let tokens = part.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let name = tokens.first else { continue }
            found[String(name)] = tokens.count > 1 ? String(tokens[1]) : ""
        }
        return found
    }

    @Test("콘솔 화면에 헤더가 붙는다")
    func addsHeadersToPages() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/") { response in
                #expect(response.headers.first(name: "X-Content-Type-Options") == "nosniff")
                #expect(response.headers.first(name: "Referrer-Policy") == "same-origin")
                // 클릭재킹을 막는 지시문. 이 미들웨어를 만든 이유다.
                #expect(directives(response)["frame-ancestors"] == "'none'")
            }
        }
    }

    @Test("오류 응답에도 헤더가 붙는다")
    func addsHeadersToErrorResponses() async throws {
        try await withMigratedApp { app in
            // 오류 화면은 오류 미들웨어가 만든다. 보안 헤더가 그보다 안쪽에 있으면
            // 404 화면만 헤더 없이 나가고, 그건 아무도 눈치채지 못한다.
            try await app.testing().test(.GET, "/없는-화면") { response in
                #expect(response.status == .notFound)
                #expect(directives(response)["frame-ancestors"] == "'none'")
            }
            // JSON 경로도 마찬가지다.
            try await app.testing().test(.GET, "\(APIPath.apiRoot)/없는-경로") { response in
                #expect(response.status == .notFound)
                #expect(response.headers.first(name: "X-Content-Type-Options") == "nosniff")
            }
        }
    }

    @Test("정적 파일에도 헤더가 붙는다")
    func addsHeadersToStaticFiles() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/console.css") { response in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Content-Type-Options") == "nosniff")
            }
        }
    }

    @Test("HSTS 는 붙이지 않는다")
    func doesNotSetHSTS() async throws {
        try await withMigratedApp { app in
            // TLS 를 끊는 자리가 붙일 몫이다. 여기서 붙이면 헤더가 둘 나가고,
            // http 로 뜬 서버가 붙이면 그 호스트를 브라우저마다 손으로 풀어야 한다.
            try await app.testing().test(.GET, "/") {
                #expect($0.headers.first(name: "Strict-Transport-Security") == nil)
            }
        }
    }

    @Test("화면이 실제로 쓰는 것만 연다")
    func policyMatchesTemplates() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/") { response in
                let policy = directives(response)
                // 열지 않은 것은 전부 막힌다.
                #expect(policy["default-src"] == "'none'")
                // `Public/upload.js` 하나뿐이고 인라인 스크립트는 없다.
                #expect(policy["script-src"] == "'self'")
                // `layout.leaf` 의 강조색 인라인 `<style>` 때문에 필요하다.
                #expect(policy["style-src"] == "'self' 'unsafe-inline'")
                // 로고와 피드백 스크린샷이 바깥 호스트다.
                #expect(policy["img-src"]?.contains("https:") == true)
                // 로그아웃 폼의 응답이 공급자로 리다이렉트한다. 그 자리가 빠지면
                // 브라우저가 이동을 막고, 화면은 아무 일도 없었던 것처럼 남는다.
                #expect(policy["form-action"]?.hasPrefix("'self'") == true)
                #expect(policy["base-uri"] == "'none'")
            }
        }
    }

    /// 이것이 빠지면 로그아웃 폼이 공급자로 가지 못한다. 쿠키는 지워졌는데 화면은
    /// 그대로라, 사람 눈에는 "로그아웃 버튼이 안 먹는다" 로 보인다.
    @Test("로그인 공급자 주소를 form-action 에 연다")
    func opensProviderOriginForLogoutForm() async throws {
        try await withConfiguredApp(
            overrides: ["OIDC_ISSUER": "http://localhost:8081/realms/alley"]
        ) { app in
            try await app.testing().test(.GET, "/") { response in
                let action = try #require(directives(response)["form-action"])
                #expect(action.contains("http://localhost:8081"))
                // 경로는 빼고 출처만 연다.
                #expect(!action.contains("/realms/alley"))
            }
        }
    }

    @Test("issuer 에서 출처만 뽑는다")
    func extractsProviderOrigin() throws {
        let config = try TestSupport.config(
            overrides: ["OIDC_ISSUER": "https://login.example.com/realms/alley"]
        )
        #expect(
            SecurityHeadersMiddleware.providerOrigin(for: config.oauth)
                == "https://login.example.com"
        )
    }

    @Test("로컬 MinIO 주소를 CSP 에 연다")
    func opensConfiguredStorageOrigin() throws {
        // 빠지면 업로드가 아무 오류 없이 멈춘다. CSP 위반은 화면에 아무 표시가 없다.
        let config = try TestSupport.config(overrides: ["S3_ENDPOINT": "http://localhost:9000"])
        #expect(SecurityHeadersMiddleware.storageOrigin(for: config.storage) == "http://localhost:9000")
    }

    @Test("브라우저에 내주는 주소가 따로 있으면 그쪽을 연다")
    func prefersPublicStorageEndpoint() throws {
        let config = try TestSupport.config(overrides: [
            "S3_ENDPOINT": "http://minio:9000",
            "S3_PUBLIC_ENDPOINT": "https://storage.example.com",
        ])
        // 브라우저가 붙는 주소는 S3_PUBLIC_ENDPOINT 쪽이다. 서버가 붙는 내부 이름을
        // 열어두면 정작 브라우저의 업로드가 막힌다.
        #expect(
            SecurityHeadersMiddleware.storageOrigin(for: config.storage)
                == "https://storage.example.com"
        )
    }

    @Test("엔드포인트를 안 주면 AWS S3 주소를 연다")
    func derivesAWSStorageOrigin() throws {
        var environment = TestSupport.minimalEnvironment
        environment["S3_REGION"] = "ap-northeast-2"
        let config = try AppConfig.load(from: environment)

        // presigned URL 을 만드는 것과 같은 함수로 주소를 얻는다. 여기서 규칙을 다시
        // 쓰면 둘이 어긋나는 날이 온다.
        #expect(
            SecurityHeadersMiddleware.storageOrigin(for: config.storage)
                == "https://alley-artifacts.s3.ap-northeast-2.amazonaws.com"
        )
    }

    @Test("가상 호스트 방식이면 버킷이 붙은 호스트를 연다")
    func derivesVirtualHostStorageOrigin() throws {
        let config = try TestSupport.config(overrides: [
            "S3_PUBLIC_ENDPOINT": "https://storage.example.com",
            "S3_USE_PATH_STYLE": "false",
        ])
        #expect(
            SecurityHeadersMiddleware.storageOrigin(for: config.storage)
                == "https://alley-artifacts.storage.example.com"
        )
    }

    @Test("업로드가 붙는 스토리지가 connect-src 에 들어간다")
    func connectSrcCoversUpload() async throws {
        // `Public/upload.js` 가 presigned URL 로 직접 PUT 한다. connect-src 가 그 주소를
        // 안 열면 업로드가 draft 에서 멈추고 화면에는 아무 표시도 없다.
        try await withMigratedApp(overrides: ["S3_PUBLIC_ENDPOINT": "https://storage.example.com"]) { app in
            try await app.testing().test(.GET, "/") { response in
                let connect = directives(response)["connect-src"]
                #expect(connect == "'self' https://storage.example.com")
            }
        }
    }
}
