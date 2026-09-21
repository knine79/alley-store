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
