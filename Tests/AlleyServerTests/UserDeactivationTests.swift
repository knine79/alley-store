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
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
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

            // 토큰은 아직 유효하다. 막는 것은 신원 쪽이다.
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(targetToken)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    /// 끊는 관리자는 대개 그 앱과 아무 관계가 없다. 함께 맡던 사람에게 간다.
    @Test("맡던 앱은 가장 먼저 들어온 공동 담당자에게 간다")
    func ownedAppsMoveToTheFirstUploader() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let (first, _) = try await app.makeUser(email: "first@example.com", role: .developer)
            let (second, _) = try await app.makeUser(email: "second@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.left", name: "두고 간 앱", owner: target
            )
            let appID = try owned.requireID()
            try await AppMember(appID: appID, userID: try first.requireID()).save(on: app.db)
            try await AppMember(appID: appID, userID: try second.requireID()).save(on: app.db)

            let result = try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )

            #expect(result.moved.count == 1)
            #expect(result.orphaned.isEmpty)
            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(reloaded.$owner.id == (try first.requireID()))
            // 오너가 됐으니 멤버 표에서는 빠진다.
            #expect(try await reloaded.canUpload(first, on: app.db))
            let rows = try await AppMember.query(on: app.db)
                .filter(\.$app.$id == appID)
                .filter(\.$user.$id == first.requireID())
                .count()
            #expect(rows == 0)
        }
    }

    /// 아무나 지목하는 것보다 비워두고 사람이 정하는 쪽이 낫다.
    @Test("함께 맡던 사람이 없으면 넘기지 않고 화면에 모아 보여준다")
    func appsWithoutUploadersAreListed() async throws {
        try await withMigratedApp { app in
            let (admin, adminToken) = try await app.makeUser(
                email: "admin@example.com", role: .admin
            )
            let (target, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let alone = try await app.seedApp(
                bundleID: "com.example.alone", name: "혼자 맡던 앱", owner: target
            )

            let result = try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )

            #expect(result.moved.isEmpty)
            #expect(result.orphaned.count == 1)
            // 오너는 그대로다. 관리자가 정할 때까지 비어 있는 자리로 남는다.
            let reloaded = try #require(try await App.find(try alone.requireID(), on: app.db))
            #expect(reloaded.$owner.id == (try target.requireID()))

            try await app.testing().test(
                .GET, "/admin/users", headers: .sessionCookie(adminToken)
            ) { response in
                #expect(response.body.string.contains("주인을 정해야 하는 앱"))
                #expect(response.body.string.contains("혼자 맡던 앱"))
            }
        }
    }

    @Test("관리자가 주인 없는 앱의 오너를 정한다")
    func adminAssignsTheOwner() async throws {
        try await withMigratedApp { app in
            let (admin, adminToken) = try await app.makeUser(
                email: "admin@example.com", role: .admin
            )
            let (target, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let (heir, _) = try await app.makeUser(email: "heir@example.com", role: .developer)
            let alone = try await app.seedApp(
                bundleID: "com.example.assign", name: "정해줄 앱", owner: target
            )
            let appID = try alone.requireID()
            try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )

            try await app.testing().test(
                .POST, "/admin/apps/\(appID.uuidString)/owner",
                headers: .form(cookie: adminToken),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try heir.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .seeOther)
            }

            let reloaded = try #require(try await App.find(appID, on: app.db))
            #expect(reloaded.$owner.id == (try heir.requireID()))
        }
    }

    /// 세션과 로그인 말고 문이 하나 더 있다. 앱이 받아둔 코드를 세션으로 바꾸는
    /// 자리다 (ADR-0061).
    @Test("받아둔 코드로도 새 세션을 받지 못한다")
    func authCodeExchangeIsBlocked() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let (plaintext, code) = AuthCode.issue(userID: try target.requireID())
            try await code.save(on: app.db)

            try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )

            try await app.testing().test(
                .POST, APIPath.tokenExchange,
                beforeRequest: { try $0.content.encode(["code": plaintext]) }
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("끊은 계정에는 업로드 권한을 줄 수 없다")
    func cannotGrantUploadToACutOffAccount() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (gone, _) = try await app.makeUser(email: "gone@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.grant", name: "권한앱", owner: owner
            )
            try await AdminOperations.deactivate(gone, by: admin, on: app.db, logger: app.logger)

            try await app.testing().test(
                .POST, "/apps/\(try registered.requireID().uuidString)/members",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try gone.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .badRequest)
            }

            let reloaded = try #require(
                try await App.find(try registered.requireID(), on: app.db)
            )
            #expect(!(try await reloaded.canUpload(gone, on: app.db)))
        }
    }

    /// 화면을 오래 열어두면 그 사이에 다른 관리자가 정했을 수 있다.
    @Test("이미 주인이 있는 앱은 다시 정하지 못한다")
    func cannotReassignAnAppThatHasAnOwner() async throws {
        try await withMigratedApp { app in
            let (admin, adminToken) = try await app.makeUser(
                email: "admin@example.com", role: .admin
            )
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (other, _) = try await app.makeUser(email: "other@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.taken", name: "주인 있는 앱", owner: owner
            )
            _ = admin

            try await app.testing().test(
                .POST, "/admin/apps/\(try registered.requireID().uuidString)/owner",
                headers: .form(cookie: adminToken),
                beforeRequest: {
                    try $0.content.encode(
                        ["userID": try other.requireID().uuidString], as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .conflict)
            }

            let reloaded = try #require(
                try await App.find(try registered.requireID(), on: app.db)
            )
            #expect(reloaded.$owner.id == (try owner.requireID()))
        }
    }

    @Test("끊긴 계정은 새 오너 후보에 나오지 않는다")
    func cutOffPeopleAreNotCandidates() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (gone, _) = try await app.makeUser(email: "gone@example.com", role: .developer)
            try await AdminOperations.deactivate(gone, by: admin, on: app.db, logger: app.logger)

            let found = try await PersonSearch.find(matching: "gone", on: app.db)
            #expect(found.candidates.isEmpty)
        }
    }

    /// 제외를 질의에 넣지 않으면, 앞쪽이 전부 이미 권한 있는 사람일 때 결과가
    /// 통째로 비어 "찾은 사람이 없습니다" 가 뜬다.
    @Test("이미 권한 있는 사람이 많아도 나머지가 보인다")
    func exclusionDoesNotEatTheWholePage() async throws {
        try await withMigratedApp { app in
            var excluded: Set<UUID> = []
            for index in 0..<(PersonSearch.limit + 1) {
                let (user, _) = try await app.makeUser(
                    email: "kim\(String(format: "%02d", index))@example.com",
                    role: .developer,
                    name: "김아무개\(index)"
                )
                excluded.insert(try user.requireID())
            }
            let (late, _) = try await app.makeUser(
                email: "kim99@example.com", role: .developer, name: "김마지막"
            )

            let found = try await PersonSearch.find(
                matching: "김", excluding: excluded, on: app.db
            )
            #expect(found.candidates.map(\.id) == [try late.requireID().uuidString])
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
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let owned = try await app.seedApp(
                bundleID: "com.example.back", name: "돌아온 사람", owner: target
            )

            let mateID = try mate.requireID()
            try await AppMember(appID: try owned.requireID(), userID: mateID).save(on: app.db)
            try await AdminOperations.deactivate(target, by: admin, on: app.db, logger: app.logger)
            try await AdminOperations.reactivate(target, by: admin, on: app.db, logger: app.logger)

            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(targetToken)) {
                #expect($0.status == .ok)
            }
            let reloaded = try #require(try await App.find(try owned.requireID(), on: app.db))
            #expect(reloaded.$owner.id == mateID)
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
