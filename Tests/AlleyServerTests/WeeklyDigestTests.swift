import AlleyShared
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 스토어 주간 소식 (이슈 #65, ADR-0076).
@Suite("스토어 주간 소식")
struct WeeklyDigestTests {
    private static let seoul = TimeZone(identifier: "Asia/Seoul")!

    /// 서울 시간으로 그때.
    private static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = seoul
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 언제

    @Test("월요일 오전 10시가 지나면 지난 월~일을 묶는다")
    func dueOnMondayMorning() throws {
        let week = try #require(WeeklyDigest.dueWeek(at: Self.at(2026, 10, 12, 10, 30), in: Self.seoul))
        #expect(week.start == Self.at(2026, 10, 5, 0))
        #expect(week.end == Self.at(2026, 10, 12, 0))
        #expect(week.previousStart == Self.at(2026, 9, 28, 0))
        #expect(week.key == "2026-10-05")
        #expect(week.label == "10월 5일 ~ 10월 11일")
    }

    @Test("보낼 때 전이거나 하루가 지났으면 보내지 않는다")
    func notDueOutsideWindow() {
        #expect(WeeklyDigest.dueWeek(at: Self.at(2026, 10, 12, 9, 59), in: Self.seoul) == nil)
        #expect(WeeklyDigest.dueWeek(at: Self.at(2026, 10, 13, 10, 1), in: Self.seoul) == nil)
        #expect(WeeklyDigest.dueWeek(at: Self.at(2026, 10, 14, 10, 30), in: Self.seoul) == nil)
    }

    // MARK: - 글

    private func ref(_ name: String) -> WeeklyDigest.Report.AppRef {
        .init(name: name, link: "https://store.example.com/a/\(name)")
    }

    @Test("조용한 주에는 한 줄만 보낸다")
    func quietWeek() {
        let messages = WeeklyDigest.compose(
            .init(storeName: "Alley Store", weekLabel: "10월 5일 ~ 10월 11일",
                  downloads: 0, previousDownloads: 3, people: 0, previousPeople: 2)
        )
        #expect(messages.newsletter.title == "📰 Alley Store 주간 소식 (10월 5일 ~ 10월 11일)")
        #expect(messages.newsletter.body == "조용한 한 주였습니다. 새로 나온 앱도 받아간 사람도 없었습니다.")
        #expect(messages.operations == nil)
    }

    @Test("소식은 항목마다 묶고 증감은 화살표로 적는다")
    func newsletterSections() throws {
        var report = WeeklyDigest.Report(
            storeName: "Alley Store", weekLabel: "10월 5일 ~ 10월 11일",
            downloads: 128, previousDownloads: 96, people: 54, previousPeople: 57
        )
        report.newApps = [.init(app: ref("클립보드"), version: "1.0", summary: "기록을 관리합니다")]
        report.updatedApps = [.init(app: ref("메모장"), version: "1.4", summary: nil)]
        report.top = [.init(app: ref("클립보드"), count: 42, previous: 0)]
        report.surging = [.init(app: ref("메모장"), count: 31, previous: 9)]
        report.feedbackCount = 12
        report.bestRated = .init(app: ref("클립보드"), average: 4.83, count: 9)
        report.newcomers = [.init(name: "홍길동", app: ref("클립보드"))]

        let body = NotificationMarkup.mrkdwn(try #require(WeeklyDigest.compose(report).newsletter.body))
        #expect(body.contains("*📊 이번 주 숫자*\n다운로드 128회 ▲32 · 받아간 사람 54명 ▼3"))
        #expect(body.contains("*🎉 새로 나온 앱*\n• <https://store.example.com/a/클립보드|클립보드> 1.0 - 기록을 관리합니다"))
        #expect(body.contains("*✨ 업데이트된 앱*\n• <https://store.example.com/a/메모장|메모장> 1.4"))
        #expect(body.contains("1. <https://store.example.com/a/클립보드|클립보드> 42회"))
        #expect(body.contains("31회 (지난주 9회의 3배)"))
        #expect(body.contains("새 피드백 12건 · 별점이 높은 앱: <https://store.example.com/a/클립보드|클립보드> ★4.8 (9명)"))
        #expect(body.contains("• 홍길동 - <https://store.example.com/a/클립보드|클립보드>"))
    }

    /// 한 통에 섞으면 옮길 때마다 운영 지표를 지워야 하고, 한 번 잊으면 전사 채널에 간다.
    @Test("운영 지표는 따로 한 통으로 보내고 해결되지 않은 실패에 링크를 단다")
    func operationsMessage() throws {
        var report = WeeklyDigest.Report(
            storeName: "Alley Store", weekLabel: "10월 5일 ~ 10월 11일",
            downloads: 1, previousDownloads: 1, people: 1, previousPeople: 1
        )
        report.failureCount = 5
        report.failuresByReason = [.init(reason: "entitlements 문제", count: 3), .init(reason: "공증 거절", count: 2)]
        report.unresolved = [.init(app: ref("기록기"), version: "2.4 (51)", reason: "entitlements 문제")]
        report.lowRated = [.init(app: ref("레거시"), average: 2.1, count: 7)]
        report.idle = [.init(app: ref("계산기"), reason: "90일 넘게 새 버전이 없습니다")]

        let operations = try #require(WeeklyDigest.compose(report).operations)
        #expect(operations.title == "🛠 Alley Store 운영 지표 (10월 5일 ~ 10월 11일)")
        let body = NotificationMarkup.mrkdwn(try #require(operations.body))
        #expect(body.hasPrefix("관리자에게만 보냅니다. 공용 채널에 전하지 마세요."))
        #expect(body.contains("*❗ 서명 실패 5건*\nentitlements 문제 3 · 공증 거절 2"))
        #expect(body.contains("아직 해결되지 않은 것:\n• <https://store.example.com/a/기록기|기록기> 2.4 (51) - entitlements 문제"))
        #expect(body.contains("*👎 별점이 낮은 앱*\n• <https://store.example.com/a/레거시|레거시> ★2.1 (7명)"))
        #expect(body.contains("*💤 쉬고 있는 앱*\n• <https://store.example.com/a/계산기|계산기> - 90일 넘게 새 버전이 없습니다"))
    }

    @Test("메일에서는 링크가 글 뒤에 주소로 붙는다")
    func linksInPlainText() {
        let text = "• " + NotificationMarkup.link("https://store.example.com/a/1", "메모장") + " 1.4"
        #expect(NotificationMarkup.plain(text) == "• 메모장 (https://store.example.com/a/1) 1.4")
        #expect(NotificationMarkup.mrkdwn(text) == "• <https://store.example.com/a/1|메모장> 1.4")
    }

    // MARK: - 보내기

    private struct Fixture {
        var admin: User
        var developer: User
        var appID: UUID
    }

    /// 지난주(10월 5일~11일)에 처음 나온 앱 하나와 다운로드 셋.
    private func seed(on app: Application) async throws -> Fixture {
        let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
        let (developer, _) = try await app.makeUser(email: "dev@example.com", role: .developer, name: "홍길동")
        let record = try await app.seedApp(bundleID: "com.example.clip", name: "클립보드", owner: developer)
        let appID = try record.requireID()
        let version = try await app.seedVersion(appID: appID, short: "1.0", build: 1, state: .released, by: developer)
        version.releasedAt = Self.at(2026, 10, 6, 15)
        try await version.save(on: app.db)

        let sql = try #require(app.db as? any SQLDatabase)
        for _ in 0..<3 {
            let download = Download(userID: try admin.requireID(), versionID: try version.requireID())
            try await download.save(on: app.db)
            try await sql.raw(
                "UPDATE downloads SET created_at = \(bind: Self.at(2026, 10, 7, 12)) WHERE id = \(bind: try download.requireID())"
            ).run()
        }
        return Fixture(admin: admin, developer: developer, appID: appID)
    }

    @Test("관리자에게 한 주에 한 번만 보낸다")
    func sendsOncePerWeekToAdmins() async throws {
        try await withMigratedApp { app in
            _ = try await seed(on: app)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)
            let monday = Self.at(2026, 10, 12, 10, 30)

            await WeeklyDigest.run(on: app, now: monday, timeZone: Self.seoul, notifier: notifier)
            await WeeklyDigest.run(on: app, now: monday.addingTimeInterval(3600), timeZone: Self.seoul, notifier: notifier)

            // 개발자는 받지 않는다. 운영 지표는 실을 것이 없어 소식 한 통만 간다.
            #expect(dm.endpoints == ["admin@example.com"])
            let message = try #require(dm.messages.first)
            #expect(message.title.contains("주간 소식 (10월 5일 ~ 10월 11일)"))
            let body = NotificationMarkup.plain(try #require(message.body))
            #expect(body.contains("다운로드 3회 ▲3 · 받아간 사람 1명 ▲1"))
            #expect(body.contains("🎉 새로 나온 앱"))
            #expect(body.contains("👋 처음 앱을 낸 개발자\n• 홍길동 - 클립보드"))
        }
    }

    @Test("주간 소식을 끈 관리자에게는 보내지 않는다")
    func respectsOptOut() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)
            fixture.admin.notifyWeeklyDigest = false
            try await fixture.admin.save(on: app.db)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)

            await WeeklyDigest.run(on: app, now: Self.at(2026, 10, 12, 10, 30), timeZone: Self.seoul, notifier: notifier)

            #expect(dm.messages.isEmpty)
        }
    }

    @Test("해결되지 않은 서명 실패가 있으면 운영 지표를 따로 보낸다")
    func sendsOperationsWhenFailing() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)
            let failed = try await app.seedVersion(
                appID: fixture.appID, short: "1.1", build: 2, state: .failed, by: fixture.developer
            )
            let job = SigningJob(versionID: try failed.requireID())
            job.state = .failed
            job.failureCode = .notarizationRejected
            job.finishedAt = Self.at(2026, 10, 8, 9)
            try await job.save(on: app.db)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)
            await WeeklyDigest.run(on: app, now: Self.at(2026, 10, 12, 10, 30), timeZone: Self.seoul, notifier: notifier)

            #expect(dm.messages.count == 2)
            let operations = NotificationMarkup.plain(try #require(dm.messages.last?.body))
            #expect(operations.contains("❗ 서명 실패 1건\n공증 거절 1"))
            #expect(operations.contains("• 클립보드 (https://store.example.com/apps/\(fixture.appID.uuidString)) 1.1 (2) - 공증 거절"))
        }
    }

    /// 스토어 앱은 모든 항목에서 뺀다. 별점 1위라고 다른 앱을 밀어내지도 않는다.
    @Test("스토어 앱은 별점과 서명 실패에서 빠진다")
    func excludesStoreApp() async throws {
        try await withMigratedApp { app in
            let fixture = try await seed(on: app)

            let store = try await app.seedApp(bundleID: "com.example.store", name: "스토어", owner: fixture.developer)
            let storeID = try store.requireID()
            let settings = try await StoreAppSettings.loadOrSeed(on: app.db, config: app.alleyConfig, logger: app.logger)
            settings.$app.id = storeID
            try await settings.save(on: app.db)
            let storeVersion = try await app.seedVersion(appID: storeID, short: "1.0", build: 1, state: .failed, by: fixture.developer)
            let job = SigningJob(versionID: try storeVersion.requireID())
            job.state = .failed
            job.failureCode = .notarizationRejected
            job.finishedAt = Self.at(2026, 10, 8, 9)
            try await job.save(on: app.db)

            let clipVersion = try #require(try await Version.query(on: app.db).filter(\.$app.$id == fixture.appID).first())
            for (index, (appID, versionID, rating)) in [
                (storeID, try storeVersion.requireID(), 5), (storeID, try storeVersion.requireID(), 5),
                (storeID, try storeVersion.requireID(), 5),
                (fixture.appID, try clipVersion.requireID(), 5), (fixture.appID, try clipVersion.requireID(), 5),
                (fixture.appID, try clipVersion.requireID(), 4),
            ].enumerated().map({ ($0.offset, $0.element) }) {
                // 한 사람은 버전마다 하나만 남긴다. 별점마다 다른 사람이다.
                let (rater, _) = try await app.makeUser(email: "rater\(index)@example.com", role: .developer)
                try await Feedback(appID: appID, versionID: versionID, userID: try rater.requireID(), rating: rating)
                    .save(on: app.db)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("UPDATE feedback SET created_at = \(bind: Self.at(2026, 10, 9, 12))").run()

            let week = try #require(WeeklyDigest.dueWeek(at: Self.at(2026, 10, 12, 10, 30), in: Self.seoul))
            let report = try await WeeklyDigest.gather(
                week, now: Self.at(2026, 10, 12, 10, 30), on: app.db, baseURL: "https://store.example.com"
            )
            #expect(report.bestRated?.app.name == "클립보드")
            #expect(report.failureCount == 0)
            #expect(report.unresolved.isEmpty)
            #expect(report.feedbackCount == 3)
        }
    }

    @Test("Slack 에서는 사람이 쓴 글의 꺾쇠를 바꿔 가짜 링크를 막는다")
    func escapesUserTextForSlack() {
        let body = "소개: <https://evil.example.com|콘솔에서 확인> & "
            + NotificationMarkup.link("https://store.example.com/a/1", "A > B")
        #expect(
            NotificationMarkup.mrkdwn(body)
                == "소개: &lt;https://evil.example.com|콘솔에서 확인&gt; &amp; <https://store.example.com/a/1|A &gt; B>"
        )
        // 메일은 평문이라 바꾸지 않는다.
        #expect(NotificationMarkup.plain(body).hasPrefix("소개: <https://evil.example.com|콘솔에서 확인> & A > B"))
    }

    // MARK: - 설정

    @Test("관리자만 내 알림에서 주간 소식 칸을 본다")
    func onlyAdminsSeeTheSetting() async throws {
        try await withMigratedApp { app in
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (_, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(.GET, "/me/notifications", headers: .sessionCookie(adminToken)) {
                #expect($0.body.string.contains("스토어 주간 소식"))
            }
            try await app.testing().test(.GET, "/me/notifications", headers: .sessionCookie(devToken)) {
                #expect(!$0.body.string.contains("스토어 주간 소식"))
            }
        }
    }

    @Test("관리자가 끄면 저장되고, 관리자가 아닌 사람의 저장은 이 값을 건드리지 않는다")
    func savesOnlyForAdmins() async throws {
        try await withMigratedApp { app in
            let (admin, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (developer, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)

            for token in [adminToken, devToken] {
                try await app.testing().test(
                    .POST, "/me/notifications",
                    headers: .form(cookie: token),
                    beforeRequest: { try $0.content.encode(["feedback": "on"], as: .urlEncodedForm) }
                ) { #expect($0.status == .ok) }
            }

            #expect(try await User.find(try admin.requireID(), on: app.db)?.notifyWeeklyDigest == false)
            #expect(try await User.find(try developer.requireID(), on: app.db)?.notifyWeeklyDigest == true)
        }
    }
}
