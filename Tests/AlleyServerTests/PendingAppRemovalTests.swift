import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 확정되지 못한 등록을 치운다 (ADR-0039).
///
/// dmg 를 올리면 번들 ID 가 임시값인 채로 앱이 만들어진다. 워커가 실패하면 그
/// 상태로 남는데, 지금까지는 치울 방법이 없었다 (ADR-0034 의 대가).
@Suite("확정 전 앱 지우기")
struct PendingAppRemovalTests {
    private func seedPending(
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

    // MARK: - 지울 수 있는가

    @Test("올린 사람이 지운다")
    func ownerRemoves() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPending(on: app, owner: owner)
            let appID = try record.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/delete", headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            #expect(try await App.find(appID, on: app.db) == nil)
        }
    }

    @Test("관리자도 지운다")
    func adminRemoves() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, adminToken) = try await app.makeUser(email: "boss@example.com", role: .admin)
            let record = try await seedPending(on: app, owner: owner)
            let appID = try record.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/delete", headers: .form(cookie: adminToken)
            ) { #expect($0.status == .seeOther) }

            #expect(try await App.find(appID, on: app.db) == nil)
        }
    }

    /// 멤버는 버전을 올릴 수는 있어도 등록 자체를 없애지는 못한다. 그건 오너의
    /// 결정이다 (`requireManageAccess`).
    @Test("남은 지우지 못한다")
    func otherPeopleCannot() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(
                email: "other@example.com", role: .developer
            )
            let record = try await seedPending(on: app, owner: owner)
            let appID = try record.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/delete", headers: .form(cookie: otherToken)
            ) { #expect($0.status == .forbidden) }

            #expect(try await App.find(appID, on: app.db) != nil)
        }
    }

    /// **번들 ID 가 정해졌다는 것은 누군가 설치했을 수 있다는 뜻이다.** 지우면
    /// 다운로드 이력과 피드백까지 함께 사라진다. 그건 다른 결정이다.
    @Test("확정된 앱은 지울 수 없다")
    func confirmedAppIsSafe() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.done", name: "확정된앱", owner: owner
            )
            let appID = try record.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/delete", headers: .form(cookie: token)
            ) { #expect($0.status == .conflict) }

            #expect(try await App.find(appID, on: app.db) != nil)
        }
    }

    // MARK: - 무엇까지 치우는가

    @Test("올린 파일과 버전도 함께 사라진다")
    func removesVersionsAndObjects() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPending(on: app, owner: owner)
            let appID = try record.requireID()

            let version = try await app.seedVersion(
                appID: appID, short: "0.0.0", build: 1, state: .uploaded, by: owner
            )
            let versionID = try version.requireID()
            let key = ArtifactStorage.objectKey(
                appID: appID, versionID: versionID, kind: .unsigned
            )
            let artifact = Artifact(
                versionID: versionID, kind: .unsigned, storageKey: key, fileSize: 2048
            )
            try await artifact.save(on: app.db)

            let storage = app.useFakeStorage()
            storage.place(key: key, size: 2048)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/delete", headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            #expect(try await App.find(appID, on: app.db) == nil)
            #expect(try await Version.find(versionID, on: app.db) == nil)
            // 행만 지우고 오브젝트를 남기면 아무도 그것을 다시 찾지 못한다.
            #expect(try await storage.head(key: key) == nil)
        }
    }

    @Test("서명 잡도 함께 사라진다")
    func removesSigningJobs() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPending(on: app, owner: owner)
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "0.0.0", build: 1, state: .failed, by: owner
            )
            try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/delete", headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            #expect(try await SigningJob.query(on: app.db).count() == 0)
        }
    }

    // MARK: - 화면

    @Test("확정 전 앱 화면에 지우는 자리가 있다")
    func detailOffersRemoval() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await seedPending(on: app, owner: owner)
            let appID = try record.requireID().uuidString

            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains("/apps/\(appID)/delete"))
                #expect(body.contains("이 등록 지우기"))
                // 되돌릴 수 없다는 것을 누르기 전에 말한다.
                #expect(body.contains("되돌릴 수 없습니다"))
            }
        }
    }

    // MARK: - 같은 앱을 또 만들지 않게

    /// 등록할 때는 번들 ID 가 임시값이라 겹치는지 알 수 없다. 겹친 사실은 워커가
    /// 확정할 때에야 드러나고, 그때는 이미 다 올린 뒤다.
    @Test("등록 화면이 확인 중인 등록을 알려준다")
    func newFormWarnsAboutPending() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            _ = try await seedPending(on: app, owner: owner, name: "먼저올린앱")

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(body.contains("아직 확인 중인 등록이"))
                #expect(body.contains("먼저올린앱"))
                #expect(body.contains("새로 만들지 마세요"))
            }
        }
    }

    @Test("남의 확인 중인 등록은 알려주지 않는다")
    func newFormHidesOtherPeople() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(
                email: "other@example.com", role: .developer
            )
            _ = try await seedPending(on: app, owner: owner, name: "남의앱")

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(otherToken)
            ) { response in
                #expect(!response.body.string.contains("남의앱"))
                #expect(!response.body.string.contains("아직 확인 중인 등록이"))
            }
        }
    }

    @Test("확인 중인 등록이 없으면 조용하다")
    func newFormQuietWithoutPending() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/apps/new", headers: .sessionCookie(token)
            ) { #expect(!$0.body.string.contains("아직 확인 중인 등록이")) }
        }
    }

    /// 겹친다는 사실이 드러나는 곳은 워커가 확정할 때 하나뿐이다. 거기서
    /// 무엇을 해야 하는지 말하지 않으면 아무도 말해주지 않는다.
    @Test("번들 ID 가 겹치면 무엇을 해야 하는지 말한다")
    func confirmCollisionExplainsWhatToDo() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            _ = try await app.seedApp(
                bundleID: "com.example.taken", name: "먼저등록된앱", owner: owner
            )
            let pendingApp = try await seedPending(on: app, owner: owner)

            do {
                try await AppRegistration.confirmBundleID(
                    pendingApp,
                    readFromBundle: "com.example.taken",
                    settings: StoreSettings(storeName: "Example", bundleIDPrefix: "com.example"),
                    on: app.db,
                    logger: app.logger
                )
                Issue.record("겹치는데 확정됐다")
            } catch let abort as any AbortError {
                #expect(abort.reason.contains("먼저등록된앱"))
                #expect(abort.reason.contains("새 버전으로 올리고"))
                #expect(abort.reason.contains("지우세요"))
            }
        }
    }

    @Test("확정된 앱 화면에는 없다")
    func confirmedDetailHasNoRemoval() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.done", name: "확정된앱", owner: owner
            )
            let appID = try record.requireID().uuidString

            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(token)
            ) { response in
                #expect(!response.body.string.contains("이 등록 지우기"))
            }
        }
    }
}
