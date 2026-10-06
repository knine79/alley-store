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

    // MARK: - 검색·정렬·분류 (이슈 #56)

    /// 화면에 나온 번들 ID 를 나온 순서대로.
    private func order(_ body: String, of bundleIDs: [String]) -> [String] {
        bundleIDs
            .compactMap { id in body.range(of: id).map { (id, $0.lowerBound) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func seedCatalog(_ app: Application, owner: User) async throws {
        let rows: [(String, String, AppCategory?, [String])] = [
            ("com.example.notes", "메모", .productivity, ["git"]),
            ("com.example.git", "Git 도우미", .developerTools, []),
            ("com.example.paint", "그림판", .design, []),
        ]
        for (bundleID, name, category, tags) in rows {
            let record = try await app.seedApp(bundleID: bundleID, name: name, owner: owner)
            record.category = category?.rawValue
            record.tags = tags
            try await record.save(on: app.db)
        }
    }

    @Test("검색어로 거르고, 이름에 걸린 앱이 태그에 걸린 앱보다 먼저 나온다")
    func searchRanksLikeStoreApp() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await seedCatalog(app, owner: owner)

            try await app.testing().test(
                .GET, "/apps?q=git", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(!body.contains("com.example.paint"))
                // 이름순으로는 어느 쪽이 앞이든 상관없이 이름에 걸린 쪽이 먼저다.
                // 스토어 앱과 같은 규칙이다.
                #expect(order(body, of: ["com.example.notes", "com.example.git"])
                    == ["com.example.git", "com.example.notes"])
                // 친 검색어가 칸에 남는다.
                #expect(body.contains(#"name="q" value="git""#))
            }
        }
    }

    @Test("분류로 거르고, 칸에는 목록에 있는 분류만 나온다")
    func filtersByCategory() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await seedCatalog(app, owner: owner)

            try await app.testing().test(
                .GET, "/apps?category=design", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains("com.example.paint"))
                #expect(!body.contains("com.example.notes"))
                #expect(body.contains(#"<option value="design" selected>"#))
                // 고르면 빈 목록이 되는 칸은 내지 않는다.
                #expect(!body.contains(#"value="business""#))
                #expect(body.contains("조건 지우기"))
            }
        }
    }

    @Test("정렬은 주소로 고르고, 모르는 값이면 이름순이다")
    func sortsFromQuery() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            // 이름순으로 넣는다. 최신 등록순이면 그 반대로 나와야 한다.
            for (bundleID, name) in [("com.example.a", "가"), ("com.example.b", "나"), ("com.example.c", "다")] {
                try await app.seedApp(bundleID: bundleID, name: name, owner: owner)
            }
            let byName = ["com.example.a", "com.example.b", "com.example.c"]

            try await app.testing().test(
                .GET, "/apps?sort=newest", headers: .sessionCookie(token)
            ) { response in
                #expect(order(response.body.string, of: byName) == byName.reversed())
                #expect(response.body.string.contains(#"<option value="newest" selected>"#))
            }
            // 손으로 고친 주소나 예전 주소로 오류 화면을 보일 이유가 없다.
            try await app.testing().test(
                .GET, "/apps?sort=nope&category=nope", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(order(response.body.string, of: byName) == byName)
                #expect(!response.body.string.contains("조건 지우기"))
            }
        }
    }

    /// 웹 콘솔은 목록을 그릴 때 다운로드 수를 따로 읽어야 한다. 빠뜨리면 모든 앱이 0 이라
    /// 이름순과 같은 순서가 나오고, 스토어 앱의 같은 정렬과 어긋난다.
    @Test("다운로드 많은 순은 받아간 횟수로 늘어놓는다")
    func sortsByDownloads() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            for (bundleID, name, count) in [
                ("com.example.a", "가", 1), ("com.example.b", "나", 0), ("com.example.c", "다", 3),
            ] {
                let record = try await app.seedApp(bundleID: bundleID, name: name, owner: owner)
                let version = try await app.seedVersion(
                    appID: try record.requireID(), short: "1.0", build: 1, state: .released, by: owner
                )
                for _ in 0..<count {
                    try await Download(userID: try owner.requireID(), versionID: try version.requireID())
                        .save(on: app.db)
                }
            }

            try await app.testing().test(
                .GET, "/apps?sort=downloads", headers: .sessionCookie(token)
            ) { response in
                #expect(order(response.body.string, of: ["com.example.a", "com.example.b", "com.example.c"])
                    == ["com.example.c", "com.example.a", "com.example.b"])
                #expect(response.body.string.contains(#"<option value="downloads" selected>"#))
            }
        }
    }

    @Test("맞는 앱이 없으면 무엇으로 찾았는지 말한다")
    func explainsNoMatch() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await seedCatalog(app, owner: owner)

            try await app.testing().test(
                .GET, "/apps?q=zzz&category=design", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains("디자인 분류에서 &#39;zzz&#39; 로 찾은 앱이 없습니다."))
                // 앱이 하나도 없을 때의 말과 섞이면 안 된다.
                #expect(!body.contains("아직 등록된 앱이 없습니다"))
            }
        }
    }

    @Test("로그인하지 않으면 로그인으로 보낸다")
    func requiresSignIn() async throws {
        try await withMigratedApp { app in
            // 로그인을 마치면 이 화면으로 돌아온다.
            try await app.testing().test(.GET, "/apps") { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "\(APIPath.googleAuthorize)?next=/apps")
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
