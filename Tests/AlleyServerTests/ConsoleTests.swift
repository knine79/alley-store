import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("웹 콘솔 화면")
struct ConsoleViewTests {
    @Test("로그인하지 않으면 로그인 화면을 준다")
    func showsLoginWhenSignedOut() async throws {
        try await withMigratedApp(overrides: [
            "STORE_NAME": "Example Store",
            "ALLOWED_EMAIL_DOMAINS": "example.com",
        ]) { app in
            try await app.testing().test(.GET, "/") { response in
                #expect(response.status == .ok)
                #expect(response.headers.contentType?.type == "text")

                let html = response.body.string
                #expect(html.contains("Example Store"))
                // 어떤 계정으로 로그인할 수 있는지 미리 알려준다.
                #expect(html.contains("example.com"))
                #expect(html.contains(APIPath.googleAuthorize))
            }
        }
    }

    @Test("허용 도메인이 없으면 화면에 경고가 뜬다")
    func warnsWhenAnyDomainCanSignIn() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/") { response in
                // 설정 실수로 로그인이 열려 있는 상태를 눈에 띄게 알린다.
                #expect(response.body.string.contains("누구나 로그인할 수 있습니다"))
            }
        }
    }

    @Test("로그인하면 사용자와 로그아웃이 보인다")
    func showsUserWhenSignedIn() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(
                email: "dev@example.com", role: .developer, name: "개발자"
            )

            try await app.testing().test(
                .GET, "/", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains("개발자"))
                #expect(html.contains("로그아웃"))
            }
        }
    }

    @Test("스토어 강조색이 화면에 실린다")
    func appliesAccentColor() async throws {
        try await withMigratedApp(overrides: ["STORE_ACCENT_COLOR": "#ff8800"]) { app in
            try await app.testing().test(.GET, "/") { response in
                #expect(response.body.string.contains("--accent: #ff8800"))
            }
        }
    }

    @Test("정적 파일이 서빙된다")
    func servesStylesheet() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/console.css") { response in
                #expect(response.status == .ok)
                #expect(response.headers.contentType?.subType == "css")
            }
        }
    }
}

@Suite("오류 응답 형식")
struct ConsoleErrorTests {
    @Test("API 경로는 JSON 오류를 준다")
    func apiPathsGetJSON() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "\(APIPath.apiRoot)/nowhere") { response in
                #expect(response.status == .notFound)
                #expect(response.headers.contentType?.subType == "json")
                // 스토어 앱과 워커가 이 형태를 디코딩한다.
                let payload = try response.content.decode(ErrorPayload.self)
                #expect(payload.error)
            }
        }
    }

    @Test("화면 경로는 사람이 읽는 오류를 준다")
    func pagePathsGetHTML() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/nowhere") { response in
                #expect(response.status == .notFound)
                #expect(response.headers.contentType?.subType == "html")
                // 사용자가 {"error":true} 를 읽게 두지 않는다.
                #expect(!response.body.string.contains("\"error\""))
                #expect(response.body.string.contains("404"))
            }
        }
    }

    @Test("헬스체크는 JSON 쪽으로 분류된다")
    func healthCountsAsMachinePath() async throws {
        // 오케스트레이터가 파싱한다. HTML 이 오면 안 된다.
        try await withMigratedApp { app in
            try await app.testing().test(.GET, APIPath.health) { response in
                #expect(response.headers.contentType?.subType == "json")
            }
        }
    }

    @Test("브라우저 세션이 끊기면 로그인으로 보낸다")
    func browserUnauthorizedRedirects() async throws {
        try await withMigratedApp { app in
            // "인증되지 않았습니다"를 읽고 스스로 로그인 주소를 찾게 할 이유가 없다.
            try await app.testing().test(.POST, "/logout") { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/")
            }
        }
    }
}

@Suite("출처 검사")
struct OriginCheckTests {
    private let settingsPath = "\(APIPath.adminRoot)/settings"

    @Test("같은 출처에서 온 쿠키 요청은 통과한다")
    func sameOriginPasses() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            var headers = HTTPHeaders.sessionCookie(token)
            headers.add(name: .origin, value: "http://localhost:8080")
            headers.replaceOrAdd(name: .host, value: "localhost:8080")

            try await app.testing().test(
                .PATCH, settingsPath, headers: headers,
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "Renamed Store"))
                }
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("다른 출처에서 온 쿠키 요청을 막는다")
    func crossOriginIsBlocked() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            var headers = HTTPHeaders.sessionCookie(token)
            headers.add(name: .origin, value: "https://evil.example")
            headers.replaceOrAdd(name: .host, value: "localhost:8080")

            // 공격자 페이지가 우리 팀원의 브라우저를 시켜 설정을 바꾸는 경로다.
            try await app.testing().test(
                .PATCH, settingsPath, headers: headers,
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "탈취됨"))
                }
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("Origin 없는 쿠키 요청을 막는다")
    func missingOriginIsBlocked() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 브라우저는 상태를 바꾸는 요청에 언제나 Origin 을 붙인다.
            // 쿠키는 있는데 Origin 이 없으면 브라우저가 보낸 것이 아니다.
            try await app.testing().test(
                .PATCH, settingsPath, headers: .sessionCookie(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "탈취됨"))
                }
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("헤더로 인증하면 Origin 없이도 통과한다")
    func bearerRequestsAreNotChecked() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 스토어 앱과 CLI 는 Origin 을 보내지 않는다. 여기서 막으면 그쪽이 죽는다.
            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "Renamed Store"))
                }
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("읽기 요청은 검사하지 않는다")
    func readsAreNotChecked() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            var headers = HTTPHeaders.sessionCookie(token)
            headers.add(name: .origin, value: "https://evil.example")

            // 남의 사이트가 링크를 걸어 우리 화면으로 이동시키는 것까지 막을 이유는 없다.
            try await app.testing().test(.GET, settingsPath, headers: headers) {
                #expect($0.status == .ok)
            }
        }
    }
}

@Suite("설정값 형식 검사")
struct StoreSettingsValidationTests {
    @Test("올바른 강조색을 소문자로 정규화한다", arguments: [
        ("#FFF", "#fff"), ("#3478F6", "#3478f6"), ("3478F6", "#3478f6"), ("#11223344", "#11223344"),
    ])
    func normalizesAccentColor(_ raw: String, _ expected: String) throws {
        #expect(try StoreSettingsValidation.validatedAccentColor(raw) == expected)
    }

    @Test("CSS 를 주입하는 강조색을 막는다", arguments: [
        "red; } body { display: none } /*", "var(--x)", "#12345", "#ggg", "",
    ])
    func rejectsMalformedAccentColor(_ raw: String) {
        // 이 값은 화면의 <style> 안에 그대로 들어간다.
        #expect(throws: (any Error).self) {
            try StoreSettingsValidation.validatedAccentColor(raw)
        }
    }

    @Test("http/https 로고 주소를 통과시킨다", arguments: [
        "https://example.com/logo.png", "http://example.com/logo.png",
    ])
    func acceptsWebLogoURL(_ raw: String) throws {
        #expect(try StoreSettingsValidation.validatedLogoURL(raw) == raw)
    }

    @Test("다른 스킴의 로고 주소를 막는다", arguments: [
        "javascript:alert(1)", "data:image/png;base64,AAAA", "/logo.png", "example.com/logo.png",
    ])
    func rejectsNonWebLogoURL(_ raw: String) {
        #expect(throws: (any Error).self) {
            try StoreSettingsValidation.validatedLogoURL(raw)
        }
    }
}
