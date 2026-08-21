import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("앱 목록 화면")
struct AppListPageTests {
    @Test("출시본이 없는 앱은 일반 사용자에게 보이지 않는다")
    func hidesUnreleasedFromRegularUsers() async throws {
        try await withMigratedApp { app in
            let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            _ = try await app.seedApp(bundleID: "com.example.hidden", name: "준비 중", owner: owner)

            // 받을 수 없는 앱이 목록에 뜨면 왜 못 받는지 묻게 된다.
            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(userToken)
            ) { response in
                #expect(!response.body.string.contains("com.example.hidden"))
            }
            // 올릴 수 있는 사람은 준비 중인 앱까지 봐야 한다.
            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(ownerToken)
            ) { response in
                #expect(response.body.string.contains("com.example.hidden"))
            }
        }
    }

    @Test("등록 버튼은 올릴 수 있는 사람에게만 보인다")
    func registerButtonIsForPublishers() async throws {
        try await withMigratedApp { app in
            let (_, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(devToken)
            ) { #expect($0.body.string.contains("/apps/new")) }

            // 누를 수 없는 버튼을 보여주고 403 을 주는 것보다 안 보이는 편이 낫다.
            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(userToken)
            ) { #expect(!$0.body.string.contains("/apps/new")) }
        }
    }

    @Test("로그인하지 않으면 로그인으로 보낸다")
    func requiresSignIn() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/apps") { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/")
            }
        }
    }
}

@Suite("앱 등록 폼")
struct AppFormPageTests
{
    @Test("올릴 권한이 없으면 폼을 못 본다")
    func formNeedsPublishRole() async throws {
        try await withMigratedApp { app in
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(userToken)
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("프리픽스 정책이 폼에 안내된다")
    func formExplainsPrefixPolicy() async throws {
        try await withMigratedApp(overrides: ["BUNDLE_ID_PREFIX": "com.example"]) { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { response in
                // 규칙을 어기고 거절당하기 전에 미리 알려준다.
                #expect(response.body.string.contains("com.example"))
            }
        }
    }

    @Test("등록에 성공하면 상세로 보낸다")
    func successRedirectsToDetail() async throws {
        try await withMigratedApp(overrides: ["BUNDLE_ID_PREFIX": "com.example"]) { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/apps/new", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        AppFormValues(bundleID: "com.example.tool", name: "도구"),
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                // POST-redirect-GET. 새로 고침이 같은 등록을 다시 보내면 안 된다.
                #expect(response.status == .seeOther)
                let location = response.headers.first(name: .location) ?? ""
                #expect(location.hasPrefix("/apps/"))
            }

            let created = try await App.query(on: app.db)
                .filter(\.$bundleID == "com.example.tool")
                .first()
            #expect(created?.name == "도구")
        }
    }

    @Test("규칙을 어기면 적은 값을 살려서 폼을 다시 준다")
    func failureKeepsWhatUserTyped() async throws {
        try await withMigratedApp(overrides: ["BUNDLE_ID_PREFIX": "com.example"]) { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/apps/new", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        AppFormValues(bundleID: "org.other.tool", name: "남의 앱", summary: "설명"),
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .badRequest)
                let html = response.body.string
                #expect(html.contains("com.example."), "무엇이 잘못됐는지 알려줘야 한다")
                // 오류 화면으로 보내면 적은 내용이 통째로 날아간다.
                #expect(html.contains("org.other.tool"))
                #expect(html.contains("남의 앱"))
                #expect(html.contains("설명"))
            }
        }
    }

    @Test("중복 번들 ID 를 폼에서도 막는다")
    func duplicateBundleIDIsRejected() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            _ = try await app.seedApp(bundleID: "com.example.taken", name: "먼저", owner: owner)

            // API 와 폼이 같은 규칙을 지나야 한다. 한쪽만 막으면 언제든 어긋난다.
            try await app.testing().test(
                .POST, "/apps/new", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        AppFormValues(bundleID: "com.example.taken", name: "나중"),
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("이미 등록"))
            }
        }
    }

    @Test("다른 출처에서 온 폼 제출을 막는다")
    func crossOriginSubmissionIsBlocked() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            var headers = HTTPHeaders.form(cookie: token)
            headers.replaceOrAdd(name: .origin, value: "https://evil.example")

            try await app.testing().test(
                .POST, "/apps/new", headers: headers,
                beforeRequest: { request in
                    try request.content.encode(
                        AppFormValues(bundleID: "com.example.evil", name: "탈취"),
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .forbidden) }

            let created = try await App.query(on: app.db)
                .filter(\.$bundleID == "com.example.evil")
                .first()
            #expect(created == nil, "막힌 요청이 앱을 만들면 안 된다")
        }
    }
}

@Suite("앱 상세 화면")
struct AppDetailPageTests {
    @Test("준비 중인 버전은 올릴 권한이 있는 사람에게만 보인다")
    func draftVersionsAreHidden() async throws {
        try await withMigratedApp { app in
            let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            try await app.seedVersion(appID: appID, short: "1.0.0", build: 100, state: .released, by: owner)
            try await app.seedVersion(appID: appID, short: "2.0.0", build: 200, state: .draft, by: owner)

            let path = "/apps/\(appID.uuidString)"

            try await app.testing().test(
                .GET, path, headers: .sessionCookie(ownerToken)
            ) { response in
                #expect(response.body.string.contains("2.0.0"))
            }
            // 출시 전 버전 번호가 새면 알려지지 않아야 할 일정이 드러난다.
            try await app.testing().test(
                .GET, path, headers: .sessionCookie(userToken)
            ) { response in
                let html = response.body.string
                #expect(html.contains("1.0.0"))
                #expect(!html.contains("2.0.0"))
            }
        }
    }

    @Test("출시본이 없는 앱은 일반 사용자에게 없는 것과 같다")
    func unreleasedAppIsNotFoundForRegularUsers() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            let record = try await app.seedApp(
                bundleID: "com.example.hidden", name: "준비 중", owner: owner
            )

            // 목록에서 감추면서 주소로는 열리면 감춘 의미가 없다.
            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)",
                headers: .sessionCookie(userToken)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("업로드 권한자에게만 멤버 목록이 보인다")
    func memberListNeedsUploadAccess() async throws {
        try await withMigratedApp { app in
            let (owner, ownerToken) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            try await app.seedVersion(appID: appID, short: "1.0.0", build: 100, state: .released, by: owner)

            let path = "/apps/\(appID.uuidString)"
            try await app.testing().test(
                .GET, path, headers: .sessionCookie(ownerToken)
            ) { #expect($0.body.string.contains("owner@example.com")) }

            // 누가 올릴 수 있는지는 조직 전체에 알릴 정보가 아니다.
            try await app.testing().test(
                .GET, path, headers: .sessionCookie(userToken)
            ) { #expect(!$0.body.string.contains("owner@example.com")) }
        }
    }

    @Test("상태 이름을 사람이 읽는 말로 보여준다")
    func showsStateNames() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            try await app.seedVersion(appID: appID, short: "1.0.0", build: 100, state: .signing, by: owner)

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                // 화면에 signing 이 아니라 사람 말이 나와야 한다.
                #expect(response.body.string.contains(VersionState.signing.displayName))
            }
        }
    }
}
