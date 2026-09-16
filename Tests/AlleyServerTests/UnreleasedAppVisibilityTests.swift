import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 출시 전인 앱을 누가 볼 수 있는가.
///
/// **출시된 앱은 모두에게 보인다.** 그것이 스토어의 뜻이다. 문제는 아직 출시하지
/// 않은 앱인데, 예전에는 "올릴 수 있는 사람이면 전부" 보여줬다. 그러면 개발자
/// 한 사람이 다른 팀이 준비 중인 앱을 이름·번들 ID·설명까지 다 본다. 아직 알리지
/// 않은 것을 목록에서 먼저 보게 되는 자리다.
///
/// 손댈 수 있는 사람에게만 보인다. 오너, 앱 멤버, 관리자다. 업로드 권한과 같은
/// 기준이라 "보이는데 못 만지는" 상태가 생기지 않는다.
@Suite("출시 전 앱은 누구에게 보이나")
struct UnreleasedAppVisibilityTests {
    /// 남의 앱 하나와, 그것을 볼 사람들.
    private func seed(
        on app: Application
    ) async throws -> (owner: User, ownerToken: String, viewer: User, viewerToken: String,
                       adminToken: String, secret: App) {
        let (theirs, theirsToken) = try await app.makeUser(
            email: "theirs@example.com", role: .developer
        )
        let (viewer, viewerToken) = try await app.makeUser(
            email: "mine@example.com", role: .developer
        )
        let (_, admin) = try await app.makeUser(email: "boss@example.com", role: .admin)

        let secret = try await app.seedApp(
            bundleID: "com.example.secret", name: "아직안알린앱", owner: theirs
        )
        // 보는 사람에게도 자기 앱을 하나 준다. 목록이 통째로 빈 것과 "남의 것만
        // 빠진 것" 을 구분해야 한다.
        _ = try await app.seedApp(
            bundleID: "com.example.mine", name: "내가만든앱", owner: viewer
        )
        return (theirs, theirsToken, viewer, viewerToken, admin, secret)
    }

    @Test("남의 출시 전 앱은 웹 목록에 나오지 않는다")
    func hiddenFromWebList() async throws {
        try await withMigratedApp { app in
            let seeded = try await seed(on: app)

            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(seeded.viewerToken)
            ) { response in
                #expect(!response.body.string.contains("아직안알린앱"))
                // 목록이 통째로 빈 것이 아니라 남의 것만 빠진 것이어야 한다.
                #expect(response.body.string.contains("내가만든앱"))
            }

            // 관리자는 본다. 운영하는 사람은 무엇이 올라와 있는지 알아야 한다.
            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(seeded.adminToken)
            ) { response in
                #expect(response.body.string.contains("아직안알린앱"))
            }

            // 오너는 자기 것을 본다. 못 보면 방금 만든 앱을 찾아갈 길이 없다.
            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(seeded.ownerToken)
            ) { response in
                #expect(response.body.string.contains("아직안알린앱"))
            }
        }
    }

    @Test("멤버로 넣으면 보인다")
    func visibleToMembers() async throws {
        try await withMigratedApp { app in
            let seeded = try await seed(on: app)

            // 올릴 수 있게 되면 보여야 한다. 보이지 않는데 올릴 수 있는 상태는
            // 그 사람이 앱을 찾아갈 방법이 없다는 뜻이다.
            try await AppMember(
                appID: try seeded.secret.requireID(), userID: try seeded.viewer.requireID()
            ).save(on: app.db)

            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(seeded.viewerToken)
            ) { response in
                #expect(response.body.string.contains("아직안알린앱"))
            }
        }
    }

    /// 스토어 앱이 쓰는 경로도 같은 규칙이어야 한다. 웹만 막고 API 를 열어두면
    /// 목록은 깨끗한데 값은 그대로 나간다.
    @Test("API 목록도 같은 규칙을 쓴다")
    func apiListFollowsTheSameRule() async throws {
        try await withMigratedApp { app in
            _ = try await seed(on: app)
            let (_, bearer) = try await app.makeUser(email: "api@example.com", role: .developer)

            try await app.testing().test(
                .GET, APIPath.apps, headers: .bearer(bearer)
            ) { response in
                let apps = try response.content.decode([AppDTO].self)
                #expect(!apps.contains { $0.name == "아직안알린앱" })
            }
        }
    }
}
