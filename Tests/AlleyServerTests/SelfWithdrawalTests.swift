import Fluent
import Testing
import Vapor

@testable import AlleyServer

/// 본인이 직접 나간다 (ADR-0063).
///
/// 관리자가 치우는 것과 끝 상태는 같지만 가는 길이 다르다. 여기서 보는 것은
/// **앱이 소유자 없이 남지 않는가**, **스토어가 잠기지 않는가**, 그리고 **누른
/// 사람이 그 자리에서 로그인을 잃는가** 셋이다.
@Suite("직접 탈퇴")
struct SelfWithdrawalTests {
    @Test("맡던 앱을 지목한 사람에게 넘기고 나간다")
    func appsGoToThePeopleYouPicked() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, _) = try await app.makeUser(email: "leaving@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.picked", name: "고른 앱", owner: leaving
            )
            let appID = try owned.requireID()
            let mateID = try mate.requireID()

            let result = try await AdminOperations.withdraw(
                leaving, handingOver: [appID: mateID], on: app.db, logger: app.logger
            )

            #expect(result.handedOver.count == 1)
            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(reloaded.$owner.id == mateID)

            let gone = try #require(try await User.find(try leaving.requireID(), on: app.db))
            #expect(!gone.isActive)
        }
    }

    /// 화면을 그린 뒤에 앱이 늘 수 있다. 그 앱이 지목되지 않은 채 지나가면
    /// 앱을 다 넘기게 한 뜻이 없어진다.
    @Test("지목하지 않은 앱이 하나라도 있으면 아무것도 바뀌지 않는다")
    func anUnassignedAppStopsEverything() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, _) = try await app.makeUser(email: "leaving@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let picked = try await app.seedApp(
                bundleID: "com.example.picked", name: "고른 앱", owner: leaving
            )
            let forgotten = try await app.seedApp(
                bundleID: "com.example.forgotten", name: "잊은 앱", owner: leaving
            )

            await #expect(throws: Abort.self) {
                try await AdminOperations.withdraw(
                    leaving,
                    handingOver: [try picked.requireID(): try mate.requireID()],
                    on: app.db, logger: app.logger
                )
            }

            // 하나도 바뀌지 않았다. 고른 앱도 그대로고 계정도 살아 있다.
            let stillMine = try #require(try await App.find(try picked.requireID(), on: app.db))
            #expect(stillMine.$owner.id == (try leaving.requireID()))
            let stillThere = try #require(try await App.find(try forgotten.requireID(), on: app.db))
            #expect(stillThere.$owner.id == (try leaving.requireID()))
            let stillActive = try #require(try await User.find(try leaving.requireID(), on: app.db))
            #expect(stillActive.isActive)
        }
    }

    /// `deactivate` 는 누른 사람이 관리자로 남아서 이 검사가 필요 없었다.
    /// 여기서는 누른 사람이 사라진다.
    @Test("마지막 관리자는 나갈 수 없다")
    func theLastAdminCannotLeave() async throws {
        try await withMigratedApp { app in
            let (only, _) = try await app.makeUser(email: "only@example.com", role: .admin)
            _ = try await app.makeUser(email: "dev@example.com", role: .developer)

            await #expect(throws: Abort.self) {
                try await AdminOperations.withdraw(only, handingOver: [:], on: app.db, logger: app.logger)
            }

            let stillActive = try #require(try await User.find(try only.requireID(), on: app.db))
            #expect(stillActive.isActive)
        }
    }

    @Test("관리자가 둘이면 한 명은 나갈 수 있다")
    func oneOfTwoAdminsCanLeave() async throws {
        try await withMigratedApp { app in
            let (first, _) = try await app.makeUser(email: "first@example.com", role: .admin)
            _ = try await app.makeUser(email: "second@example.com", role: .admin)

            try await AdminOperations.withdraw(first, handingOver: [:], on: app.db, logger: app.logger)

            let gone = try #require(try await User.find(try first.requireID(), on: app.db))
            #expect(!gone.isActive)
        }
    }

    /// 넘겨받은 사람이 못 들어오면 그 앱은 그 자리에서 다시 소유자를 잃는다.
    @Test("탈퇴 처리된 사람에게는 넘길 수 없다")
    func youCannotHandOverToSomeoneWhoLeft() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, _) = try await app.makeUser(email: "leaving@example.com", role: .developer)
            let (gone, _) = try await app.makeUser(email: "gone@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.picked", name: "고른 앱", owner: leaving
            )
            try await AdminOperations.deactivate(gone, by: admin, on: app.db, logger: app.logger)

            await #expect(throws: Abort.self) {
                try await AdminOperations.withdraw(
                    leaving,
                    handingOver: [try owned.requireID(): try gone.requireID()],
                    on: app.db, logger: app.logger
                )
            }

            let stillActive = try #require(try await User.find(try leaving.requireID(), on: app.db))
            #expect(stillActive.isActive)
        }
    }

    @Test("자기 자신에게는 넘길 수 없다")
    func youCannotHandOverToYourself() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, _) = try await app.makeUser(email: "leaving@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.picked", name: "고른 앱", owner: leaving
            )

            await #expect(throws: Abort.self) {
                try await AdminOperations.withdraw(
                    leaving,
                    handingOver: [try owned.requireID(): try leaving.requireID()],
                    on: app.db, logger: app.logger
                )
            }
        }
    }

    /// 90일 사는 값이라 나간 사람 손에 남겨둘 수 없다 (ADR-0060).
    @Test("나가면 내가 낸 토큰도 함께 폐기된다")
    func leavingRevokesYourTokens() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, _) = try await app.makeUser(email: "leaving@example.com", role: .developer)
            _ = try await app.makeUserToken(for: leaving, name: "노트북")

            try await AdminOperations.withdraw(leaving, handingOver: [:], on: app.db, logger: app.logger)

            let alive = try await UserToken.query(on: app.db)
                .filter(\.$user.$id == (try leaving.requireID()))
                .filter(\.$revokedAt == nil)
                .count()
            #expect(alive == 0)
        }
    }

    @Test("이미 나간 계정은 다시 나갈 수 없다")
    func leavingTwiceIsRefused() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, _) = try await app.makeUser(email: "leaving@example.com", role: .developer)
            try await AdminOperations.deactivate(leaving, by: admin, on: app.db, logger: app.logger)

            await #expect(throws: Abort.self) {
                try await AdminOperations.withdraw(leaving, handingOver: [:], on: app.db, logger: app.logger)
            }
        }
    }

    // MARK: - 화면

    /// 앱을 다 정하기 전에는 나갈 수 없어야 한다. 버튼을 잠그는 것으로는 부족하다.
    /// 주소를 손으로 만들면 폼을 지나쳐 들어온다.
    @Test("고르지 않은 앱이 있으면 화면이 탈퇴 버튼을 잠근다")
    func theButtonStaysLockedUntilEveryAppHasAnHeir() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, token) = try await app.makeUser(
                email: "leaving@example.com", role: .developer
            )
            _ = try await app.seedApp(bundleID: "com.example.solo", name: "혼자 맡는 앱", owner: leaving)

            try await app.testing().test(
                .GET, "/me/withdraw", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("아직 소유권 이전 받을 사람을 정하지 않은 앱이 있습니다"))
            }
        }
    }

    /// 고른 값을 주소에 싣고 다니는 것이 이 화면의 핵심이다. 앱마다 검색이 따로 있어서
    /// 한 앱을 찾는 동안 화면이 다시 그려진다.
    @Test("주소에 실어 보낸 선택이 화면에 남는다")
    func choicesSurviveTheNextSearch() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, token) = try await app.makeUser(
                email: "leaving@example.com", role: .developer
            )
            let (heir, _) = try await app.makeUser(email: "heir@example.com", role: .developer)
            let solo = try await app.seedApp(
                bundleID: "com.example.solo", name: "혼자 맡는 앱", owner: leaving
            )
            let pair = "\(try solo.requireID().uuidString):\(try heir.requireID().uuidString)"

            try await app.testing().test(
                .GET, "/me/withdraw?assignment=\(pair)", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("heir@example.com"))
                #expect(!response.body.string.contains("아직 소유권 이전 받을 사람을 정하지 않은 앱이 있습니다"))
            }
        }
    }

    @Test("이메일이 맞지 않으면 나가지 않는다")
    func theTypedEmailMustMatch() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, token) = try await app.makeUser(
                email: "leaving@example.com", role: .developer
            )

            try await app.testing().test(
                .POST, "/me/withdraw", headers: .form(cookie: token),
                body: .init(string: "confirm=wrong@example.com")
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("이메일이 맞지 않습니다"))
            }

            let stillActive = try #require(try await User.find(try leaving.requireID(), on: app.db))
            #expect(stillActive.isActive)
        }
    }

    /// 나가고 나면 무엇이 누구에게 갔는지 한 번은 보여주고 보낸다.
    @Test("나가면 이전한 앱을 보여주고 세션 쿠키를 지운다")
    func theLastScreenShowsWhatMoved() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, token) = try await app.makeUser(
                email: "leaving@example.com", role: .developer
            )
            let (heir, _) = try await app.makeUser(email: "heir@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.solo", name: "혼자 맡는 앱", owner: leaving
            )
            let pair = "\(try owned.requireID().uuidString):\(try heir.requireID().uuidString)"

            try await app.testing().test(
                .POST, "/me/withdraw", headers: .form(cookie: token),
                body: .init(string: "confirm=leaving@example.com&assignment=\(pair)")
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("탈퇴했습니다"))
                #expect(response.body.string.contains("혼자 맡는 앱"))
                // 이 브라우저에 남은 쿠키도 함께 끝낸다.
                #expect(response.headers.setCookie?[sessionCookieName] != nil)
            }
        }
    }
}
