import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 다운로드가 있는 앱 하나.
private struct StatsSetup {
    var owner: User
    var ownerToken: String
    var appID: UUID
    var versionID: UUID
}

private func seedDownloads(on app: Application, people: Int, times: Int) async throws -> StatsSetup {
    let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
    let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
    let appID = try record.requireID()
    let version = try await app.seedVersion(
        appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
    )
    let versionID = try version.requireID()

    for index in 0..<people {
        let (user, _) = try await app.makeUser(email: "user\(index)@example.com", role: .user)
        for _ in 0..<times {
            try await Download(userID: try user.requireID(), versionID: versionID)
                .save(on: app.db)
        }
    }

    return StatsSetup(owner: owner, ownerToken: ownerToken, appID: appID, versionID: versionID)
}

@Suite("다운로드 집계")
struct DownloadStatsTests {
    @Test("전체와 사람 수를 따로 센다")
    func countsTotalAndPeople() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 3, times: 2)

            let summary = try await DownloadStats.summary(ofApp: setup.appID, on: app.db)
            #expect(summary.total == 6)
            // 같은 사람이 여러 번 받아도 하나로 센다.
            #expect(summary.people == 3)
            #expect(summary.recent == 6)
        }
    }

    @Test("오래된 다운로드는 최근에서 빠진다")
    func excludesOldFromRecent() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 1, times: 1)
            let old = Download(
                userID: try setup.owner.requireID(),
                versionID: setup.versionID
            )
            try await old.save(on: app.db)
            // 저장 후에 시각을 되돌린다. @Timestamp 가 생성 시각을 덮어쓰기 때문이다.
            old.createdAt = Date().addingTimeInterval(-60 * 24 * 60 * 60)
            try await old.save(on: app.db)

            let summary = try await DownloadStats.summary(ofApp: setup.appID, on: app.db)
            #expect(summary.total == 2)
            #expect(summary.recent == 1)
        }
    }

    @Test("버전별로 나눠 센다")
    func countsPerVersion() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 2, times: 1)
            let second = try await app.seedVersion(
                appID: setup.appID, short: "1.1.0", build: 2, state: .released, by: setup.owner
            )
            try await Download(
                userID: try setup.owner.requireID(), versionID: try second.requireID()
            ).save(on: app.db)

            let counts = try await DownloadStats.perVersion(ofApp: setup.appID, on: app.db)
            #expect(counts[setup.versionID] == 2)
            #expect(counts[try second.requireID()] == 1)
        }
    }

    @Test("다운로드가 없는 앱도 목록에 남는다")
    func keepsAppsWithoutDownloads() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 1, times: 1)
            _ = try await app.seedApp(
                bundleID: "com.example.quiet", name: "아무도 안 받는 앱", owner: setup.owner
            )

            // 목록에서 사라지면 그 사실을 알 수 없다. 그게 가장 알고 싶은 것 중 하나다.
            let overview = try await DownloadStats.overview(on: app.db)
            #expect(overview.rows.count == 2)
            #expect(overview.rows.contains { $0.appName == "아무도 안 받는 앱" && $0.total == 0 })
        }
    }

    @Test("전체 합계를 낸다")
    func totalsAcrossApps() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 2, times: 2)
            let other = try await app.seedApp(
                bundleID: "com.example.other", name: "다른 앱", owner: setup.owner
            )
            let version = try await app.seedVersion(
                appID: try other.requireID(), short: "1.0.0", build: 1,
                state: .released, by: setup.owner
            )
            try await Download(
                userID: try setup.owner.requireID(), versionID: try version.requireID()
            ).save(on: app.db)

            let overview = try await DownloadStats.overview(on: app.db)
            #expect(overview.totalDownloads == 5)
            // 앱 둘을 받은 사람이 있어도 사람은 한 번만 센다.
            #expect(overview.activePeople == 3)
        }
    }
}

@Suite("통계 화면")
struct StatsPageTests {
    @Test("관리자가 아니면 볼 수 없다")
    func requiresAdmin() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .GET, "/admin/stats", headers: .sessionCookie(token)
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("앱별 숫자를 보여준다")
    func showsPerAppNumbers() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 2, times: 3)
            _ = setup
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .GET, "/admin/stats", headers: .sessionCookie(adminToken)
            ) { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains("도구"))
                #expect(html.contains(">6<"))
                // "설치"라고 적으면 없는 것을 아는 척하게 된다.
                #expect(html.contains("다운로드"))
            }
        }
    }

    @Test("앱 상세에는 올릴 수 있는 사람에게만 보인다")
    func detailNumbersAreForUploaders() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 1, times: 1)
            let (_, readerToken) = try await app.makeUser(
                email: "reader@example.com", role: .user
            )
            let path = "/apps/\(setup.appID.uuidString)"

            try await app.testing().test(
                .GET, path, headers: .sessionCookie(setup.ownerToken)
            ) { #expect($0.body.string.contains("받아간 사람")) }

            // 받는 사람에게는 쓸 데가 없는 숫자다.
            try await app.testing().test(
                .GET, path, headers: .sessionCookie(readerToken)
            ) { #expect(!$0.body.string.contains("받아간 사람")) }
        }
    }
}
