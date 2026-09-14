import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("관리자 화면 접근")
struct AdminPageAccessTests {
    @Test(
        "관리자가 아니면 볼 수 없다",
        arguments: [
            "/admin", "/admin/settings", "/admin/users", "/admin/workers",
            "/admin/stats", "/admin/portal",
        ]
    )
    func nonAdminsAreBlocked(_ path: String) async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(.GET, path, headers: .sessionCookie(token)) {
                #expect($0.status == .forbidden)
            }
        }
    }

    @Test("관리 메뉴는 관리자에게만 보인다")
    func chromeLinkIsForAdmins() async throws {
        try await withMigratedApp { app in
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (_, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(.GET, "/apps", headers: .sessionCookie(adminToken)) {
                #expect($0.body.string.contains("/admin/settings"))
            }
            // 누를 수 없는 메뉴를 보여주고 403 을 주는 것보다 안 보이는 편이 낫다.
            try await app.testing().test(.GET, "/apps", headers: .sessionCookie(devToken)) {
                #expect(!$0.body.string.contains("/admin/settings"))
            }
        }
    }

    @Test("관리 첫 장은 설정으로 보낸다")
    func adminHomeRedirects() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await app.testing().test(.GET, "/admin", headers: .sessionCookie(token)) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/admin/settings")
            }
        }
    }
}

@Suite("관리자 화면 탭")
struct AdminNavTests {
    /// 화면마다 다른 부분집합을 링크로 놓던 것을 하나로 모았다. 그래서 확인할 것은
    /// "다섯 칸이 어느 화면에서나 같은 순서로 있는가" 다. 여기 적힌 순서가 곧 기대값이고,
    /// 근거는 `AdminTab` 에 있다.
    static let expectedOrder = ["스토어 설정", "역할 관리", "서명 워커", "개발자 포털", "통계"]

    @Test("다섯 화면 전부에서 같은 순서로 나오고 지금 있는 곳이 표시된다", arguments: AdminTab.allCases)
    func tabsAreIdenticalOnEveryAdminPage(_ current: AdminTab) async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .GET, current.path, headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                let nav = try #require(
                    Self.tabBar(in: response.body.string),
                    "\(current.path) 에 탭이 없습니다."
                )

                // 순서가 화면마다 다르면 "어디로 갈 수 있나" 가 화면마다 달라 보인다.
                #expect(Self.labels(in: nav) == Self.expectedOrder)

                // 지금 있는 곳은 링크가 아니어야 한다. 눌러도 아무 일이 안 일어나는
                // 클릭을 남겨두지 않는다.
                #expect(
                    nav.contains(
                        #"<span class="tab tab-current" aria-current="page">\#(current.title)</span>"#
                    )
                )
                #expect(!nav.contains(#"href="\#(current.path)""#))

                // 나머지 넷은 눌러서 갈 수 있어야 한다.
                for other in AdminTab.allCases where other != current {
                    #expect(nav.contains(#"<a class="tab" href="\#(other.path)">"#))
                }
            }
        }
    }

    @Test("관리자 화면이 아니면 탭이 나오지 않는다", arguments: ["/apps", "/login"])
    func tabsDoNotLeakOutsideAdminPages(_ path: String) async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 관리자로 봐도 안 나와야 한다. 역할이 아니라 "지금 관리자 화면인가" 로
            // 갈리는 값이라서다 (`PageContext.adminTabs`).
            try await app.testing().test(.GET, path, headers: .sessionCookie(token)) { response in
                #expect(Self.tabBar(in: response.body.string) == nil)
            }
        }
    }

    /// 탭 묶음만 떼어낸다. 본문에도 `/admin/...` 링크가 있을 수 있어서 화면 전체를
    /// 문자열로 훑으면 탭을 보는 것인지 알 수 없다.
    private static func tabBar(in html: String) -> String? {
        guard let start = html.range(of: #"<nav class="tabs""#),
              let end = html.range(of: "</nav>", range: start.upperBound..<html.endIndex)
        else { return nil }
        return String(html[start.lowerBound..<end.upperBound])
    }

    /// 탭에 적힌 글자를 나온 순서대로.
    private static func labels(in nav: String) -> [String] {
        nav.split(separator: "<").compactMap { chunk in
            guard chunk.hasPrefix(#"a class="tab""#)
                || chunk.hasPrefix(#"span class="tab tab-current""#)
            else { return nil }
            guard let close = chunk.firstIndex(of: ">") else { return nil }
            let text = chunk[chunk.index(after: close)...]
            return text.isEmpty ? nil : String(text)
        }
    }
}

@Suite("스토어 설정 화면")
struct StoreSettingsPageTests {
    @Test("현재 값이 폼에 채워진다")
    func showsCurrentValues() async throws {
        try await withMigratedApp(overrides: [
            "STORE_NAME": "Example Store",
            "ALLOWED_EMAIL_DOMAINS": "example.com,example.org",
        ]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .GET, "/admin/settings", headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("Example Store"))
                // 도메인은 쉼표로 나눈 한 줄로 다룬다.
                #expect(html.contains("example.com, example.org"))
            }
        }
    }

    @Test("프리픽스 강제 여부가 체크 상태로 나타난다", arguments: [true, false])
    func reflectsCheckboxState(_ enforced: Bool) async throws {
        try await withMigratedApp(
            overrides: ["ENFORCE_BUNDLE_ID_PREFIX": enforced ? "true" : "false"]
        ) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 켜져 있는 설정이 꺼진 것처럼 보이면, 저장 버튼을 누르는 순간 실제로 꺼진다.
            //
            // 화면에 체크박스가 여럿이라 "checked" 가 있는지만 보면 안 된다.
            // 줄바꿈을 접어서 그 입력 하나만 확인한다.
            try await app.testing().test(
                .GET, "/admin/settings", headers: .sessionCookie(token)
            ) { response in
                let flat = response.body.string
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                #expect(
                    flat.contains(#"name="enforceBundleIDPrefix" value="on" checked"#) == enforced
                )
            }
        }
    }

    @Test("저장하면 설정이 바뀐다")
    func savesChanges() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/settings", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        [
                            "storeName": "새 이름",
                            "accentColor": "#FF8800",
                            "allowedEmailDomains": "Example.com , example.com",
                            "bundleIDPrefix": "com.example",
                            "enforceBundleIDPrefix": "on",
                        ],
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/admin/settings?saved=1")
            }

            let stored = try #require(
                try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            )
            #expect(stored.storeName == "새 이름")
            // 강조색은 저장할 때 정규화된다.
            #expect(stored.accentColor == "#ff8800")
            // 중복과 대소문자를 정리한다.
            #expect(stored.allowedEmailDomains == ["example.com"])
            #expect(stored.$updatedBy.id == (try admin.requireID()))
        }
    }

    @Test("저장한 뒤 화면에 표시가 남는다")
    func showsSavedNotice() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 같은 화면으로 돌아오므로 아무 표시가 없으면 저장이 됐는지 알 수 없다.
            try await app.testing().test(
                .GET, "/admin/settings?saved=1", headers: .sessionCookie(token)
            ) { #expect($0.body.string.contains("저장했습니다")) }
        }
    }

    @Test("도메인을 비우려면 확인이 필요하다")
    func emptyingDomainsNeedsConfirmation() async throws {
        try await withMigratedApp(overrides: ["ALLOWED_EMAIL_DOMAINS": "example.com"]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/settings", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        ["storeName": "Example Store", "allowedEmailDomains": ""],
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                // 오류 화면으로 보내면 무엇을 고쳐야 하는지가 폼에서 멀어진다.
                #expect(response.status == .badRequest)
                #expect(response.headers.contentType?.subType == "html")
                #expect(response.body.string.contains("허용 도메인"))
            }

            let stored = try #require(
                try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            )
            #expect(stored.allowedEmailDomains == ["example.com"])
        }
    }

    @Test("확인을 켜면 도메인을 비울 수 있다")
    func confirmedEmptyingIsAllowed() async throws {
        try await withMigratedApp(overrides: ["ALLOWED_EMAIL_DOMAINS": "example.com"]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/settings", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        [
                            "storeName": "Example Store",
                            "allowedEmailDomains": "",
                            "confirmOpenToAnyDomain": "on",
                        ],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(
                try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            )
            #expect(stored.allowedEmailDomains.isEmpty)
        }
    }

    @Test("체크를 끄면 프리픽스 강제가 풀린다")
    func unsentCheckboxTurnsOff() async throws {
        try await withMigratedApp(overrides: ["ENFORCE_BUNDLE_ID_PREFIX": "true"]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 체크박스는 꺼져 있으면 아예 전송되지 않는다. 폼이 화면의 모든 항목을
            // 한 번에 보내므로 없다는 것이 곧 껐다는 뜻이다.
            try await app.testing().test(
                .POST, "/admin/settings", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        ["storeName": "Example Store", "allowedEmailDomains": "example.com"],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(
                try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            )
            #expect(!stored.enforceBundleIDPrefix)
        }
    }

    @Test("형식이 틀린 강조색은 적은 값을 그대로 되돌려준다")
    func keepsTypedValuesOnFailure() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/settings", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        [
                            "storeName": "고친 이름",
                            "accentColor": "red; } body { display: none }",
                            "allowedEmailDomains": "example.com",
                        ],
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .badRequest)
                // 한 칸 틀렸다고 나머지를 다시 적게 하지 않는다.
                #expect(response.body.string.contains("고친 이름"))
            }
        }
    }
}

@Suite("역할 관리 화면")
struct RolePageTests {
    @Test("사용자 목록이 뜬다")
    func listsUsers() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = try await app.makeUser(email: "dev@example.com", role: .developer, name: "개발자")

            try await app.testing().test(
                .GET, "/admin/users", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("dev@example.com"))
                // 지금 역할이 골라져 있지 않으면, 다른 항목을 바꾸려다 이 사람의
                // 역할까지 목록 맨 위 값으로 되돌려버린다.
                #expect(response.body.string.contains("value=\"developer\" selected"))
            }
        }
    }

    @Test("역할을 바꾸면 반영된다")
    func changesRole() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "user@example.com", role: .user)
            let targetID = try target.requireID()

            try await app.testing().test(
                .POST, "/admin/users/\(targetID.uuidString)/role", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(["role": "developer"], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/admin/users")
            }

            let stored = try #require(try await User.find(targetID, on: app.db))
            #expect(stored.role == .developer)
        }
    }

    @Test("마지막 관리자는 강등할 수 없다")
    func protectsLastAdmin() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let adminID = try admin.requireID()

            // 아무도 설정을 못 바꾸는 상태를 만들지 않는다.
            try await app.testing().test(
                .POST, "/admin/users/\(adminID.uuidString)/role", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(["role": "user"], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("마지막 관리자"))
            }

            let stored = try #require(try await User.find(adminID, on: app.db))
            #expect(stored.role == .admin)
        }
    }

    @Test("알 수 없는 역할은 거절한다")
    func rejectsUnknownRole() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .POST, "/admin/users/\(try target.requireID().uuidString)/role",
                headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(["role": "superuser"], as: .urlEncodedForm)
                }
            ) { #expect($0.status == .badRequest) }
        }
    }
}

@Suite("서명 워커 화면")
struct WorkerPageTests {
    @Test("토큰은 발급 직후 한 번만 보인다")
    func showsTokenOnce() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            var issued: String?
            try await app.testing().test(
                .POST, "/admin/workers", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(["name": "build-mac-01"], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .created)
                let html = response.body.string
                #expect(html.contains("alleyw_"))
                issued = html
            }
            _ = try #require(issued)

            // 서버는 해시만 갖고 있어서 다음 화면에서 다시 보여줄 방법이 없다.
            try await app.testing().test(
                .GET, "/admin/workers", headers: .sessionCookie(token)
            ) { response in
                #expect(response.body.string.contains("build-mac-01"))
                #expect(!response.body.string.contains("alleyw_"))
            }
        }
    }

    @Test("발급한 토큰이 실제로 통한다")
    func issuedTokenWorks() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let created = try await AdminOperations.registerWorker(
                named: "build-mac-01", by: admin, on: app.db, logger: app.logger
            )

            // 화면에 찍히는 문자열과 워커가 실제로 쓰는 문자열이 같아야 한다.
            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(created.token)
            ) { #expect($0.status == .noContent) }
        }
    }

    @Test("폐기하면 토큰이 즉시 막힌다")
    func revokingBlocksToken() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (admin, cookie) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let created = try await AdminOperations.registerWorker(
                named: "build-mac-01", by: admin, on: app.db, logger: app.logger
            )

            try await app.testing().test(
                .POST, "/admin/workers/\(created.worker.id.uuidString)/revoke",
                headers: .form(cookie: cookie)
            ) { #expect($0.status == .seeOther) }

            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(created.token)
            ) { #expect($0.status == .unauthorized) }

            // 잡 이력이 이 워커를 가리키므로 행은 남는다.
            let stored = try #require(try await Worker.find(created.worker.id, on: app.db))
            #expect(stored.revokedAt != nil)
        }
    }

    @Test("폐기한 워커는 접어둔 목록으로 내려간다")
    func revokedWorkersAreFolded() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (admin, cookie) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = try await AdminOperations.registerWorker(
                named: "build-mac-01", by: admin, on: app.db, logger: app.logger
            )
            let retired = try await AdminOperations.registerWorker(
                named: "build-mac-99", by: admin, on: app.db, logger: app.logger
            )

            try await app.testing().test(
                .POST, "/admin/workers/\(retired.worker.id.uuidString)/revoke",
                headers: .form(cookie: cookie)
            ) { #expect($0.status == .seeOther) }

            try await app.testing().test(
                .GET, "/admin/workers", headers: .sessionCookie(cookie)
            ) { response in
                let html = response.body.string
                // 기록이므로 화면에서 사라지지는 않는다. 접어둘 뿐이다.
                #expect(html.contains("build-mac-99"))
                #expect(html.contains("폐기된 워커 1개 보기"))
                // 현역은 접히지 않는다.
                #expect(html.contains("build-mac-01"))
            }
        }
    }

    @Test("이름이 비면 발급하지 않는다")
    func rejectsEmptyName() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/workers", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(["name": "   "], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("워커 이름"))
            }
        }
    }
}
