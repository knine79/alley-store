import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 등록이 끝나지 않은 앱을 어떻게 다루는가.
///
/// dmg 로 올리면 번들 ID 가 임시값인 채로 앱이 만들어진다. 워커가 번들을 열어
/// 확정하기 전까지 그 앱은 **어떤 앱인지 정해지지 않은 상태**다 (ADR-0034).
@Suite("확정 전 앱")
struct PendingAppVisibilityTests {
    /// 임시 번들 ID 를 가진 앱 하나.
    private func seedPendingApp(
        on app: Application,
        owner: User,
        name: String = "확인 중인 앱"
    ) async throws -> App {
        let record = try await app.seedApp(
            bundleID: AppRegistration.provisionalBundleID(), name: name, owner: owner
        )
        record.bundleIDPending = true
        try await record.save(on: app.db)
        return record
    }

    @Test("목록에 나오지 않는다")
    func hiddenFromList() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            _ = try await seedPendingApp(on: app, owner: owner, name: "확인중인앱")
            _ = try await app.seedApp(
                bundleID: "com.example.done", name: "확정된앱", owner: owner
            )

            try await app.testing().test(.GET, "/apps", headers: .sessionCookie(token)) { response in
                let body = response.body.string
                #expect(body.contains("확정된앱"))
                // 임시값은 어디에도 나오면 안 된다. 자리를 채우려고 넣은 값이지
                // 이 앱의 정체성이 아니다.
                #expect(!body.contains(AppRegistration.provisionalPrefix))

                // 이름은 위쪽 안내줄에 링크로 나오는 것이 설계다(찾아갈 길). 목록
                // **카드**에 없는지를 본다. 안내줄을 걷어내고 본문만 남겨서 비교한다.
                let withoutNotice = body.replacingOccurrences(
                    of: "(?s)<p class=\"notice notice-warn\".*?</p>",
                    with: "",
                    options: .regularExpression
                )
                #expect(!withoutNotice.contains("확인중인앱"))
            }
        }
    }

    /// **감추기만 하면 워커가 실패했을 때 찾을 방법이 없다.** 목록에서 빼되 올린
    /// 사람에게는 가는 길을 남긴다.
    @Test("올린 사람에게는 찾아갈 길이 남는다")
    func ownerSeesAWayBack() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPendingApp(on: app, owner: owner, name: "확인중인앱")

            let appID = try record.requireID().uuidString
            try await app.testing().test(.GET, "/apps", headers: .sessionCookie(token)) { response in
                let body = response.body.string
                #expect(body.contains("확인 중인 등록이"))
                #expect(body.contains(appID))
            }
        }
    }

    @Test("남의 확인 중인 앱은 보이지 않는다")
    func otherPeopleDoNotSeeIt() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(
                email: "other@example.com", role: .developer
            )
            _ = try await seedPendingApp(on: app, owner: owner, name: "남의확인중인앱")

            try await app.testing().test(
                .GET, "/apps", headers: .sessionCookie(otherToken)
            ) { response in
                let body = response.body.string
                #expect(!body.contains("남의확인중인앱"))
                #expect(!body.contains("확인 중인 등록이"))
            }
        }
    }

    /// 스토어 앱은 `CFBundleIdentifier` 로 설치 여부를 판단한다. 임시값인 채로
    /// 내보내면 받은 사람의 맥에서 영영 "설치 안 됨" 으로 남는다.
    @Test("확정 전에는 출시할 수 없다")
    func cannotRelease() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPendingApp(on: app, owner: owner)
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
            )
            let versionID = try version.requireID()

            try await app.testing().test(
                .POST,
                "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/release",
                headers: .form(cookie: token)
            ) { #expect($0.status == .conflict) }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .ready)
        }
    }

    @Test("확정되면 출시할 수 있다")
    func canReleaseOnceConfirmed() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPendingApp(on: app, owner: owner)
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
            )
            let versionID = try version.requireID()

            record.bundleID = "com.example.confirmed"
            record.bundleIDPending = false
            try await record.save(on: app.db)

            try await app.testing().test(
                .POST,
                "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/release",
                headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .released)
        }
    }
}
