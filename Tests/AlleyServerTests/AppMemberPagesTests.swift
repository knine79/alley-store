import AlleyShared
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 업로드 권한을 화면에서 주고 거둔다.
///
/// 지금까지는 API 로만 됐고 화면에는 "아직 API 로만 됩니다" 한 줄이 있었다. 앱을
/// 둘이 올리려면 그 한 줄 때문에 사람을 찾아가야 했다.
@Suite("업로드 권한을 화면에서 준다")
struct AppMemberPagesTests {
    private func seedApp(on app: Application, owner: User) async throws -> App {
        try await app.seedApp(bundleID: "com.example.members", name: "멤버앱", owner: owner)
    }

    @Test("찾아서 고르면 올릴 수 있게 된다")
    func addingGrantsUpload() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(
                email: "mate@example.com", role: .developer, name: "동료"
            )
            let registered = try await seedApp(on: app, owner: owner)
            let appID = try registered.requireID().uuidString
            let mateID = try mate.requireID().uuidString

            try await app.testing().test(
                .POST, "/apps/\(appID)/members",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["userID": mateID], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .seeOther)
            }

            let reloaded = try #require(try await App.find(try registered.requireID(), on: app.db))
            #expect(try await reloaded.canUpload(mate, on: app.db))
        }
    }

    // MARK: - 치는 동안 찾기

    /// 화면이 다시 그려지는 것과 **같은 것을 본다.** 둘이 갈리면 스크립트가 있을
    /// 때와 없을 때 다른 사람이 나온다.
    @Test("치는 동안 찾는 경로가 같은 후보를 돌려준다")
    func incrementalSearchMatchesThePage() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            _ = try await app.makeUser(email: "mate@example.com", role: .developer, name: "동료")
            let registered = try await seedApp(on: app, owner: owner)
            let appID = try registered.requireID().uuidString

            try await app.testing().test(
                .GET, "/apps/\(appID)/member-candidates?q=동료",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                let found = try response.content.decode(CandidatesPayload.self)
                #expect(found.candidates.map(\.email) == ["mate@example.com"])
                #expect(!found.overflowed)
            }

            // 오너는 이미 올릴 수 있다. 눌러도 아무 일이 없는 줄을 보여줄 이유가 없다.
            try await app.testing().test(
                .GET, "/apps/\(appID)/member-candidates?q=owner",
                headers: .sessionCookie(token)
            ) { response in
                let found = try response.content.decode(CandidatesPayload.self)
                #expect(found.candidates.isEmpty)
            }
        }
    }

    /// 빈 검색어로 전체 계정 목록이 새지 않게 한다.
    @Test("검색어가 없으면 아무도 돌려주지 않는다")
    func emptyQueryReturnsNothing() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            _ = try await app.makeUser(email: "mate@example.com", role: .developer, name: "동료")
            let registered = try await seedApp(on: app, owner: owner)

            try await app.testing().test(
                .GET, "/apps/\(try registered.requireID())/member-candidates?q=%20",
                headers: .sessionCookie(token)
            ) { response in
                let found = try response.content.decode(CandidatesPayload.self)
                #expect(found.candidates.isEmpty)
            }
        }
    }

    /// 누가 이 앱을 올릴 수 있는지는 관리하는 사람만 본다. 목록을 그리는 쪽과 같은
    /// 조건이어야 한다.
    @Test("관리 권한이 없으면 후보를 볼 수 없다")
    func candidatesNeedManageAccess() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(
                email: "other@example.com", role: .developer
            )
            let registered = try await seedApp(on: app, owner: owner)

            try await app.testing().test(
                .GET, "/apps/\(try registered.requireID())/member-candidates?q=owner",
                headers: .sessionCookie(otherToken)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// 눌러도 아무 일이 없는 줄을 보여줄 이유가 없다.
    @Test("이미 올릴 수 있는 사람은 검색에 나오지 않는다")
    func alreadyGrantedIsHidden() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            _ = try await app.makeUser(email: "mate@example.com", role: .developer, name: "동료")
            let registered = try await seedApp(on: app, owner: owner)
            let appID = try registered.requireID().uuidString

            // 찾으면 나온다.
            try await app.testing().test(
                .GET, "/apps/\(appID)?member=%EB%8F%99%EB%A3%8C",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.body.string.contains("mate@example.com"))
                #expect(response.body.string.contains("권한 주기"))
            }

            // 오너는 표에 없어도 올릴 수 있다. 그래서 후보에도 없다.
            try await app.testing().test(
                .GET, "/apps/\(appID)?member=owner",
                headers: .sessionCookie(token)
            ) { response in
                #expect(!response.body.string.contains("권한 주기"))
            }
        }
    }

    @Test("이름으로도 이메일로도 찾힌다", arguments: ["%EB%8F%99%EB%A3%8C", "mate"])
    func searchesNameAndEmail(_ query: String) async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            _ = try await app.makeUser(email: "mate@example.com", role: .developer, name: "동료")
            let registered = try await seedApp(on: app, owner: owner)
            let appID = try registered.requireID().uuidString

            try await app.testing().test(
                .GET, "/apps/\(appID)?member=\(query)",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.body.string.contains("mate@example.com"))
            }
        }
    }

    @Test("거두면 다시 못 올린다")
    func removingRevokesUpload() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let registered = try await seedApp(on: app, owner: owner)
            let appID = try registered.requireID()
            let mateID = try mate.requireID()
            try await AppMember(appID: appID, userID: mateID).save(on: app.db)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/members/\(mateID.uuidString)/remove",
                headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .seeOther)
            }

            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(!(try await reloaded.canUpload(mate, on: app.db)))
        }
    }

    /// 멤버는 올릴 수만 있고 관리하지는 못한다. 남을 끌어들이는 것은 오너 몫이다.
    @Test("멤버는 다른 사람에게 권한을 주지 못한다")
    func membersCannotGrant() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (mate, mateToken) = try await app.makeUser(
                email: "mate@example.com", role: .developer
            )
            let (outsider, _) = try await app.makeUser(email: "out@example.com", role: .developer)
            let registered = try await seedApp(on: app, owner: owner)
            let appID = try registered.requireID()
            try await AppMember(appID: appID, userID: try mate.requireID()).save(on: app.db)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/members",
                headers: .form(cookie: mateToken),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try outsider.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}

/// 후보 응답을 테스트에서 읽으려고 둔다. 서버 쪽 타입은 내보내기만 한다.
private struct CandidatesPayload: Content {
    struct Candidate: Content {
        var id: String
        var email: String
        var name: String
    }
    var candidates: [Candidate]
    var overflowed: Bool
}
