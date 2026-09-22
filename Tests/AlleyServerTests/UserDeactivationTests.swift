import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 나간 사람을 끊는다 (ADR-0061).
///
/// 행을 지우지 않고 시각만 남긴다. 확인할 것은 셋이다. 끊긴 사람이 못 들어오는가,
/// 맡고 있던 앱이 주인 없이 남지 않는가, 스토어가 잠기지 않는가.
@Suite("계정 끊기")
struct UserDeactivationTests {
    @Test("끊으면 이미 들고 있던 세션도 막힌다")
    func existingSessionStopsWorking() async throws {
        try await withMigratedApp { app in
            let (admin, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, targetToken) = try await app.makeUser(
                email: "leaver@example.com", role: .developer
            )

            // 끊기 전에는 들어와진다.
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(targetToken)) {
                #expect($0.status == .ok)
            }

            try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )
            _ = adminToken

            // 토큰은 아직 유효하다. 막는 것은 신원 쪽이다.
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(targetToken)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test("맡고 있던 앱은 끊은 관리자에게 넘어간다")
    func ownedAppsMoveToTheAdmin() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.left", name: "두고 간 앱", owner: target
            )

            let moved = try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )

            #expect(moved.count == 1)
            let reloaded = try #require(try await App.find(try owned.requireID(), on: app.db))
            #expect(reloaded.$owner.id == (try admin.requireID()))
        }
    }

    /// 누르는 사람이 자기 로그인을 잃으면 되돌릴 화면에도 못 들어간다.
    @Test("자기 계정은 끊을 수 없다")
    func cannotDeactivateSelf() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let adminID = try admin.requireID().uuidString

            try await app.testing().test(
                .POST, "/admin/users/\(adminID)/deactivate", headers: .form(cookie: token)
            ) { response in
                #expect(response.status == .badRequest)
            }

            let reloaded = try #require(try await User.find(try admin.requireID(), on: app.db))
            #expect(reloaded.isActive)
        }
    }

    /// 아무도 들어올 수 없는 스토어를 만들지 않는다.
    @Test("마지막 관리자는 끊을 수 없다")
    func cannotDeactivateTheLastAdmin() async throws {
        try await withMigratedApp { app in
            let (first, _) = try await app.makeUser(email: "first@example.com", role: .admin)
            let (second, secondToken) = try await app.makeUser(
                email: "second@example.com", role: .admin
            )
            let firstID = try first.requireID().uuidString

            // 둘이 있을 때는 한 명을 끊을 수 있다.
            try await app.testing().test(
                .POST, "/admin/users/\(firstID)/deactivate", headers: .form(cookie: secondToken)
            ) { response in
                #expect(response.status == .seeOther)
            }

            // 남은 한 명은 자기를 끊을 수 없고, 끊긴 관리자는 남은 수에 들지 않는다.
            await #expect(throws: (any Error).self) {
                try await AdminOperations.changeRole(
                    of: second, to: .developer, by: second, on: app.db, logger: app.logger
                )
            }
        }
    }

    @Test("되살리면 다시 들어올 수 있지만 앱은 돌아오지 않는다")
    func reactivationDoesNotReturnApps() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, targetToken) = try await app.makeUser(
                email: "leaver@example.com", role: .developer
            )
            let owned = try await app.seedApp(
                bundleID: "com.example.back", name: "돌아온 사람", owner: target
            )

            try await AdminOperations.deactivate(target, by: admin, on: app.db, logger: app.logger)
            try await AdminOperations.reactivate(target, by: admin, on: app.db, logger: app.logger)

            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(targetToken)) {
                #expect($0.status == .ok)
            }
            let reloaded = try #require(try await App.find(try owned.requireID(), on: app.db))
            #expect(reloaded.$owner.id == (try admin.requireID()))
        }
    }
}

/// 오너를 사람 손으로 넘기는 길 (ADR-0061).
@Suite("앱 오너 넘기기")
struct AppOwnerTransferTests {
    @Test("올릴 수 있는 사람에게 넘기면 옛 오너는 멤버로 남는다")
    func transferKeepsPreviousOwnerAsMember() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.handover", name: "넘길 앱", owner: owner
            )
            let appID = try registered.requireID()
            try await AppMember(appID: appID, userID: try mate.requireID()).save(on: app.db)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/owner",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try mate.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .seeOther)
            }

            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(reloaded.$owner.id == (try mate.requireID()))
            // 넘긴 사람이 올리지 못하게 되면 되돌릴 사람이 사라진다.
            #expect(try await reloaded.canUpload(owner, on: app.db))
        }
    }

    @Test("올릴 수 없는 사람에게는 넘길 수 없다")
    func cannotTransferToAStranger() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (stranger, _) = try await app.makeUser(
                email: "stranger@example.com", role: .developer
            )
            let registered = try await app.seedApp(
                bundleID: "com.example.stranger", name: "남의 앱", owner: owner
            )
            let appID = try registered.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/owner",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try stranger.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .badRequest)
            }

            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(reloaded.$owner.id == (try owner.requireID()))
        }
    }

    /// 끊은 계정이 오너가 되면 그 앱은 그 자리에서 주인을 잃는다.
    @Test("끊은 계정에는 넘길 수 없다")
    func cannotTransferToADeactivatedAccount() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (leaver, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.gone", name: "떠난 사람", owner: owner
            )
            let appID = try registered.requireID()
            try await AppMember(appID: appID, userID: try leaver.requireID()).save(on: app.db)
            try await AdminOperations.deactivate(leaver, by: admin, on: app.db, logger: app.logger)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/owner",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try leaver.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .badRequest)
            }

            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(reloaded.$owner.id == (try owner.requireID()))
        }
    }
}
