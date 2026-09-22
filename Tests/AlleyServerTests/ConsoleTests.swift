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

    @Test("로그인하면 첫 화면이 앱 목록으로 보낸다")
    func signedInHomeGoesToApps() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            // 콘솔에 들어와서 하려는 일은 대개 앱을 보거나 올리는 것이다.
            // 중간에 한 장을 더 두면 매번 한 번씩 더 눌러야 한다.
            try await app.testing().test(
                .GET, "/", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/apps")
            }
        }
    }

    @Test("로그인하면 껍데기에 사용자와 로그아웃이 보인다")
    func chromeShowsUserWhenSignedIn() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(
                email: "dev@example.com", role: .developer, name: "개발자"
            )

            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(token)
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

    /// **본문 문단에 폭 제한을 따로 걸지 않는다.**
    ///
    /// `.page` 가 이미 880px 에서 멈춘다. 여기에 또 제한을 걸면 화면 끝이 한참
    /// 남았는데 문단만 중간에서 접히고, 읽는 사람은 왜 여기서 끊기는지 알 수 없다.
    ///
    /// 두 번 겪었다. 처음에는 `max-width: 68ch` 였는데 `ch` 가 숫자 `0` 한 글자의
    /// 폭이라 한글에서는 34 자에서 끊겼다. 단위를 `em` 으로 고쳤더니 이번에는
    /// 44em(704px)이 화면의 832px 보다 좁아서 여전히 일찍 끊겼다. 단위가 아니라
    /// **제한을 거는 것 자체**가 문제였다.
    ///
    /// 상자 폭(로그인 카드, 팝업, 이름 줄임)은 글 길이가 아니라 요소 크기라 여기서
    /// 보지 않는다.
    @Test("본문 문단의 줄 길이를 따로 제한하지 않는다")
    func paragraphsUseTheFullWidth() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/console.css") { response in
                let css = response.body.string

                // `ch` 는 한글 폭을 절반으로 잰다. 길이를 재는 자리 어디에도 쓰지 않는다.
                #expect(!css.contains("ch;"))

                for selector in [".page-lead", ".section-lead", ".body-text", ".failure"] {
                    #expect(
                        !declarations(of: selector, in: css).contains("max-width"),
                        "\(selector) 에 줄 길이 제한이 다시 붙었습니다"
                    )
                }
            }
        }
    }

    /// 선택자 하나의 선언 블록을 꺼낸다. 앞뒤 규칙이 섞이지 않게 `{`부터 `}`까지만 본다.
    private func declarations(of selector: String, in css: String) -> String {
        guard let start = css.range(of: "\n\(selector) {"),
              let end = css.range(of: "}", range: start.upperBound..<css.endIndex)
        else {
            return ""
        }
        return String(css[start.upperBound..<end.lowerBound])
    }
}

@Suite("정적 파일 캐시")
struct StaticCacheTests {
    @Test("정적 파일은 쓸 때마다 서버에 물어보게 한다")
    func assetsRevalidate() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/console.css") { response in
                // Cache-Control 이 없으면 브라우저가 자기 판단으로 캐시한다.
                // 그러면 고친 CSS 가 조용히 반영되지 않는다.
                #expect(response.headers.first(name: .cacheControl) == "no-cache")
                #expect(response.headers.first(name: .eTag) != nil)
            }
        }
    }

    @Test("화면 응답에는 붙이지 않는다")
    func pagesAreNotTaggedAsAssets() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/") { response in
                #expect(response.headers.first(name: .cacheControl) == nil)
            }
        }
    }

    @Test("정적 파일 주소에 지문이 붙는다")
    func stylesheetURLIsFingerprinted() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/") { response in
                // Cache-Control 은 새로 받는 응답에만 걸린다. 이미 캐시된 항목까지
                // 확실히 갈아치우려면 주소가 바뀌어야 한다.
                #expect(response.body.string.contains("/console.css?v="))
            }
        }
    }

    @Test("파일이 그대로면 지문도 그대로다")
    func fingerprintIsStableForSameFiles() async throws {
        try await withMigratedApp { app in
            let first = AssetVersion(publicDirectory: app.directory.publicDirectory).value
            let second = AssetVersion(publicDirectory: app.directory.publicDirectory).value
            // 매번 달라지면 캐시가 아무 의미가 없어진다.
            #expect(first == second)
            #expect(!first.isEmpty)
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

    /// 로그아웃은 우리 쪽 쿠키만 지운다. 공급자 세션은 그대로라, 표시를 남기지 않으면
    /// 로그인 버튼 한 번으로 같은 계정에 그대로 들어간다.
    @Test("로그아웃하면 다음 로그인에서 다시 인증하라는 표시를 남긴다")
    func logoutMarksReauthentication() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.POST, "/logout") { response in
                let cookies = try #require(response.headers.setCookie)
                let session = try #require(cookies[sessionCookieName])
                #expect(session.string.isEmpty)

                let mark = try #require(cookies[reauthenticationCookieName])
                #expect(!mark.string.isEmpty)
                // 로그아웃하고 바로 다시 들어오는 흐름만 잡으면 된다.
                #expect((mark.maxAge ?? 0) > 0)
            }
        }
    }

    @Test("표시를 들고 로그인하러 가면 그 표시를 지운다")
    func authorizeClearsReauthenticationMark() async throws {
        try await withConfiguredApp { app in
            // 표시가 남아 있으면 그 뒤로 로그인할 때마다 비밀번호를 다시 묻게 된다.
            var headers = HTTPHeaders()
            headers.cookie = HTTPCookies(dictionaryLiteral: (reauthenticationCookieName, .init(string: "1")))

            try await app.testing().test(.GET, APIPath.googleAuthorize, headers: headers) { response in
                let cookies = try #require(response.headers.setCookie)
                let mark = try #require(cookies[reauthenticationCookieName])
                #expect(mark.string.isEmpty)
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
