import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 스토어 앱이 그리는 목록과 상세가 받는 값.
@Suite("앱 목록 API")
struct AppListAPITests {
    /// 아이콘을 받아둔 앱과, 그 앱에 로그인한 사람의 세션.
    private func seed(on app: Application) async throws -> (App, String) {
        let (owner, session) = try await app.makeUser(
            email: "dev@example.com", role: .developer, name: "김개발"
        )
        let record = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
        record.iconURL = "/apps/\(try record.requireID().uuidString)/icon.png?v=1"
        try await record.save(on: app.db)
        return (record, session)
    }

    @Test("아이콘 주소를 절대 주소로 준다")
    func iconURLIsAbsolute() async throws {
        try await withMigratedApp { app in
            let (record, session) = try await seed(on: app)
            let expected = "https://store.example.com/apps/\(try record.requireID().uuidString)/icon.png?v=1"

            // 스토어 앱은 받은 문자열을 그대로 URL 로 만든다. 상대 주소는 호스트가 없어
            // 그림을 부르지 못하고 목록의 아이콘이 모두 빈 자리로 나왔다.
            try await app.testing().test(.GET, APIPath.apps, headers: .sessionCookie(session)) { response in
                let apps = try response.content.decode([AppDTO].self)
                #expect(apps.first?.iconURL == expected)
            }
            try await app.testing().test(
                .GET, "\(APIPath.apps)/\(try record.requireID().uuidString)",
                headers: .sessionCookie(session)
            ) { response in
                let detail = try response.content.decode(AppDTO.self)
                #expect(detail.iconURL == expected)
            }
        }
    }

    @Test("밖에 있는 아이콘 주소는 그대로 둔다")
    func externalIconURLIsUntouched() {
        // 예전에는 사람이 아이콘 주소를 적어 넣었다. 이미 절대 주소다.
        #expect(App.absolute("https://cdn.example.com/a.png", base: "https://store.example.com")
            == "https://cdn.example.com/a.png")
        #expect(App.absolute("//cdn.example.com/a.png", base: "https://store.example.com")
            == "//cdn.example.com/a.png")
        #expect(App.absolute("/apps/x/icon.png", base: "https://store.example.com/")
            == "https://store.example.com/apps/x/icon.png")
    }

    @Test("개발자 이름을 소유자부터 모두 준다")
    func includesDeveloperNames() async throws {
        try await withMigratedApp { app in
            let (record, session) = try await seed(on: app)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer, name: "이동료")
            let (leaver, _) = try await app.makeUser(email: "left@example.com", role: .developer, name: "박퇴사")
            for user in [mate, leaver] {
                try await AppMember(appID: try record.requireID(), userID: try user.requireID()).save(on: app.db)
            }
            // 나간 사람은 뺀다. 물어볼 수 없는 사람이다.
            leaver.deactivatedAt = Date()
            try await leaver.save(on: app.db)

            try await app.testing().test(.GET, APIPath.apps, headers: .sessionCookie(session)) { response in
                let apps = try response.content.decode([AppDTO].self)
                #expect(apps.first?.developerNames == ["김개발", "이동료"])
            }
            try await app.testing().test(
                .GET, "\(APIPath.apps)/\(try record.requireID().uuidString)",
                headers: .sessionCookie(session)
            ) { response in
                let detail = try response.content.decode(AppDTO.self)
                #expect(detail.developerNames == ["김개발", "이동료"])
            }
        }
    }
}
