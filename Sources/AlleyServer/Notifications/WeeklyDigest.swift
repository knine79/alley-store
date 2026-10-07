import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 지난 한 주의 스토어 소식을 모아 관리자에게 보낸다 (이슈 #65, ADR-0076).
///
/// **두 통으로 나눠 보낸다.** 하나는 공용 채널에 그대로 옮겨 붙일 소식이고, 하나는
/// 관리자만 볼 운영 지표다. 한 통에 섞으면 옮길 때마다 운영 지표를 지워야 하고, 한 번
/// 잊으면 서명 실패 목록이 전사 채널에 올라간다.
///
/// 스토어가 공용 채널에 직접 올리지 않는다. 사람이 한 번 보고 다듬어 전하는 편이
/// 숫자만 늘어놓은 봇 글보다 읽힌다.
enum WeeklyDigest {
    /// 얼마나 자주 볼지. 보낼 때(월요일 오전 10시)를 놓치지 않을 만큼만.
    static let checkInterval: Duration = .seconds(3600)

    /// 월요일 몇 시에 보낼지. 서버 시간대 기준이다.
    static let sendHour = 10
    /// 보낼 때를 지나 이만큼 안에서만 보낸다. 서버가 그 사이 내내 꺼져 있었으면 그
    /// 주는 건너뛴다. 수요일에 지난주 소식이 오면 소식이 아니다.
    static let sendWindow: TimeInterval = 24 * 3600

    // MARK: - 기준

    /// 많이 받은 앱을 몇 개까지 싣나.
    static let topCount = 3
    /// 갑자기 많이 받은 앱: 그 주에 이만큼 이상이면서
    static let surgeMinimum = 10
    /// 지난주의 이 배 이상.
    static let surgeRatio = 2
    /// 별점 평균을 믿으려면 몇 명은 남겨야 한다.
    static let ratingMinimumCount = 3
    static let highRating = 4.5
    static let lowRating = 3.0
    /// 이만큼 새 버전이 없으면 쉬고 있는 앱이다.
    static let staleReleaseDays = 90
    /// 이만큼 받아간 사람이 없으면 쉬고 있는 앱이다.
    static let idleDownloadDays = 30
    /// 운영 지표 목록 하나에 몇 줄까지 늘어놓나. 넘치면 "외 N개" 로 줄인다. 앱이 많은
    /// 스토어에서 쉬고 있는 앱이 첫 주부터 수백 줄이 되면 아무도 읽지 않는다.
    static let listLimit = 10

    // MARK: - 돌리기

    /// 보낼 때가 됐으면 한 주를 모아 보낸다. 이미 보낸 주는 다시 보내지 않는다.
    ///
    /// `notifier` 와 `timeZone` 은 시험이 넣는다.
    static func run(
        on application: Application,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        notifier: Notifier? = nil
    ) async {
        guard let week = dueWeek(at: now, in: timeZone) else { return }
        let database = application.db
        let logger = application.logger

        // **먼저 차지한다.** 서버가 여러 대이거나 다시 떠도 한 주에 한 번만 간다.
        guard await claim(week, on: database, logger: logger) else { return }

        let report: Report
        do {
            report = try await gather(week, now: now, on: database, baseURL: application.alleyConfig.publicBaseURL)
        } catch {
            logger.error("주간 소식을 모으지 못했습니다: \(error)")
            // 모으지 못했으면 보낸 것으로 치지 않는다. 다음 시간에 다시 해본다.
            await unclaim(week, on: database, logger: logger)
            return
        }

        let recipients: [User]
        do {
            recipients = try await User.query(on: database)
                .filter(\.$role == .admin)
                .filter(\.$deactivatedAt == nil)
                .filter(\.$notifyWeeklyDigest == true)
                .all()
        } catch {
            logger.error("주간 소식을 받을 관리자를 읽지 못했습니다: \(error)")
            await unclaim(week, on: database, logger: logger)
            return
        }

        let notifier = notifier ?? Notifier(
            database: database, channels: application.notificationChannels, logger: logger
        )
        let messages = compose(report)
        var delivered = 0
        for admin in recipients {
            var reached = await notifier.notify(person: admin, message: messages.newsletter)
            if let operations = messages.operations {
                reached = await notifier.notify(person: admin, message: operations) || reached
            }
            if reached { delivered += 1 }
        }
        logger.notice("스토어 주간 소식 [\(week.label), 받은 관리자 \(delivered)/\(recipients.count)명]")
    }

    // MARK: - 언제

    /// 묶을 한 주. 월요일 0시부터 다음 월요일 0시 전까지다.
    struct Week: Equatable {
        var start: Date
        var end: Date
        /// 지난주. 증감을 견줄 때 쓴다.
        var previousStart: Date
        /// 차지할 때 쓰는 이름. 그 주 월요일의 날짜다.
        var key: String
        /// 사람이 읽는 기간. `10월 5일 ~ 10월 11일`
        var label: String
    }

    /// 지금 보낼 주. 보낼 때가 아니면 nil.
    static func dueWeek(at now: Date, in timeZone: TimeZone) -> Week? {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        guard let thisMonday = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              // 경과 시간으로 더하지 않는다. 그 사이 서머타임이 바뀌면 9시나 11시가 된다.
              let sendAt = calendar.date(bySettingHour: sendHour, minute: 0, second: 0, of: thisMonday),
              now >= sendAt, now.timeIntervalSince(sendAt) < sendWindow,
              let start = calendar.date(byAdding: .day, value: -7, to: thisMonday),
              let previousStart = calendar.date(byAdding: .day, value: -14, to: thisMonday),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: thisMonday)
        else { return nil }

        let keyFormat = DateFormatter()
        keyFormat.calendar = calendar
        keyFormat.timeZone = timeZone
        keyFormat.locale = Locale(identifier: "en_US_POSIX")
        keyFormat.dateFormat = "yyyy-MM-dd"

        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = timeZone
        dayFormat.locale = Locale(identifier: "ko_KR")
        dayFormat.dateFormat = "M월 d일"

        return Week(
            start: start,
            end: thisMonday,
            previousStart: previousStart,
            key: keyFormat.string(from: start),
            label: "\(dayFormat.string(from: start)) ~ \(dayFormat.string(from: lastDay))"
        )
    }

    /// 그 주를 차지한다. 다른 서버가 먼저 차지했으면 false.
    ///
    /// 데이터베이스 오류는 "이미 보냄" 과 다르다. 로그에 남겨야 테이블이 없다는 것 같은
    /// 일을 알아챈다.
    private static func claim(_ week: Week, on database: any Database, logger: Logger) async -> Bool {
        guard let sql = database as? any SQLDatabase else { return false }
        do {
            let rows = try await sql.raw(
                """
                INSERT INTO \(ident: WeeklyDigestRun.schema) (week, sent_at)
                VALUES (\(bind: week.key), now())
                ON CONFLICT (week) DO NOTHING
                RETURNING week
                """
            ).all()
            return !rows.isEmpty
        } catch {
            logger.error("주간 소식을 보낼 주를 적지 못했습니다 [\(week.key)]: \(error)")
            return false
        }
    }

    /// 차지한 것을 내려놓는다. 못 내려놓으면 그 주는 보내지 않은 채로 남는다.
    private static func unclaim(_ week: Week, on database: any Database, logger: Logger) async {
        guard let sql = database as? any SQLDatabase else { return }
        do {
            try await sql.raw(
                "DELETE FROM \(ident: WeeklyDigestRun.schema) WHERE week = \(bind: week.key)"
            ).run()
        } catch {
            logger.error("주간 소식 기록을 지우지 못했습니다. 이 주는 가지 않습니다 [\(week.key)]: \(error)")
        }
    }

    // MARK: - 모으기

    /// 한 주에 일어난 일. 글을 쓰는 쪽(`compose`)은 데이터베이스를 모른다.
    struct Report: Equatable {
        struct AppRef: Equatable {
            var name: String
            /// 소식에서는 공유 링크, 운영 지표에서는 콘솔 상세.
            var link: String
        }
        struct Release: Equatable {
            var app: AppRef
            var version: String
            var summary: String?
        }
        struct Count: Equatable {
            var app: AppRef
            var count: Int
            var previous: Int
        }
        struct Rated: Equatable {
            var app: AppRef
            var average: Double
            var count: Int
        }
        struct Newcomer: Equatable {
            var name: String
            var app: AppRef
        }
        struct Failure: Equatable {
            var app: AppRef
            var version: String
            var reason: String
        }
        struct Idle: Equatable {
            var app: AppRef
            var reason: String
        }
        struct ReasonCount: Equatable {
            var reason: String
            var count: Int
        }

        var storeName: String
        var weekLabel: String
        var downloads: Int
        var previousDownloads: Int
        var people: Int
        var previousPeople: Int
        var newApps: [Release] = []
        var updatedApps: [Release] = []
        var top: [Count] = []
        var surging: [Count] = []
        var feedbackCount: Int = 0
        var bestRated: Rated?
        var newcomers: [Newcomer] = []
        // 운영 지표
        var failureCount: Int = 0
        var failuresByReason: [ReasonCount] = []
        var unresolved: [Failure] = []
        var unresolvedOverflow: Int = 0
        var lowRated: [Rated] = []
        var lowRatedOverflow: Int = 0
        var idle: [Idle] = []
        var idleOverflow: Int = 0

        /// 소식으로 전할 것이 하나도 없는 주.
        var isQuiet: Bool {
            downloads == 0 && newApps.isEmpty && updatedApps.isEmpty && feedbackCount == 0
        }

        var hasOperations: Bool {
            failureCount > 0 || !unresolved.isEmpty || !lowRated.isEmpty || !idle.isEmpty
        }
    }

    static func gather(
        _ week: Week, now: Date, on database: any Database, baseURL: String
    ) async throws -> Report {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "주간 소식은 SQL 데이터베이스가 있어야 모읍니다.")
        }
        let base = baseURL.trimmingSuffix("/")
        // 스토어 앱은 모든 항목에서 뺀다. 스스로 업데이트하는 앱이라 소식이 아니다.
        let storeAppID = try await StoreAppSettings.find(StoreAppSettings.singletonID, on: database)?.$app.id
        let storeName = try await StoreSettings.find(StoreSettings.singletonID, on: database)?.storeName
            ?? "Alley Store"

        // 이름과 링크를 붙이려고 앱을 한 번에 읽는다. 앱은 많아야 수백 개다.
        let apps = try await App.query(on: database).with(\.$owner).all()
        var byID: [UUID: App] = [:]
        for app in apps { if let id = app.id, id != storeAppID { byID[id] = app } }
        func shared(_ id: UUID) -> Report.AppRef? {
            byID[id].map { Report.AppRef(name: $0.name, link: "\(base)\(AppLink.webPath(appID: id))") }
        }
        func console(_ id: UUID) -> Report.AppRef? {
            byID[id].map { Report.AppRef(name: $0.name, link: "\(base)/apps/\(id.uuidString)") }
        }

        // 숫자
        let totals = try await sql.raw(
            """
            SELECT
              COUNT(d.id) FILTER (WHERE d.created_at >= \(bind: week.start) AND d.created_at < \(bind: week.end)) AS downloads,
              COUNT(DISTINCT d.user_id) FILTER (WHERE d.created_at >= \(bind: week.start) AND d.created_at < \(bind: week.end)) AS people,
              COUNT(d.id) FILTER (WHERE d.created_at >= \(bind: week.previousStart) AND d.created_at < \(bind: week.start)) AS previous_downloads,
              COUNT(DISTINCT d.user_id) FILTER (WHERE d.created_at >= \(bind: week.previousStart) AND d.created_at < \(bind: week.start)) AS previous_people
            FROM downloads d JOIN versions v ON v.id = d.version_id
            WHERE \(bind: storeAppID)::uuid IS NULL OR v.app_id <> \(bind: storeAppID)
            """
        ).first()
        var report = Report(
            storeName: storeName,
            weekLabel: week.label,
            downloads: try totals?.decode(column: "downloads", as: Int.self) ?? 0,
            previousDownloads: try totals?.decode(column: "previous_downloads", as: Int.self) ?? 0,
            people: try totals?.decode(column: "people", as: Int.self) ?? 0,
            previousPeople: try totals?.decode(column: "previous_people", as: Int.self) ?? 0
        )

        // 앱별 다운로드. 이번 주와 지난주.
        struct PerApp: Decodable { var app_id: UUID; var current: Int; var previous: Int }
        let perApp = try await sql.raw(
            """
            SELECT v.app_id,
              COUNT(d.id) FILTER (WHERE d.created_at >= \(bind: week.start) AND d.created_at < \(bind: week.end)) AS current,
              COUNT(d.id) FILTER (WHERE d.created_at >= \(bind: week.previousStart) AND d.created_at < \(bind: week.start)) AS previous
            FROM downloads d JOIN versions v ON v.id = d.version_id
            WHERE d.created_at >= \(bind: week.previousStart) AND d.created_at < \(bind: week.end)
            GROUP BY v.app_id
            """
        ).all(decoding: PerApp.self)
        let counts = perApp.compactMap { row in
            shared(row.app_id).map { Report.Count(app: $0, count: row.current, previous: row.previous) }
        }
        report.top = Array(
            counts.filter { $0.count > 0 }
                .sorted { ($0.count, $1.app.name) > ($1.count, $0.app.name) }
                .prefix(topCount)
        )
        report.surging = counts
            .filter { $0.count >= surgeMinimum && $0.count >= $0.previous * surgeRatio }
            .sorted { $0.count > $1.count }

        // 출시. 그 주에 나온 버전 중 앱마다 가장 높은 빌드.
        struct Released: Decodable { var app_id: UUID; var short_version: String; var build_number: Int }
        let released = try await sql.raw(
            """
            SELECT app_id, short_version, build_number FROM versions
            WHERE state = 'released' AND released_at >= \(bind: week.start) AND released_at < \(bind: week.end)
            ORDER BY build_number DESC
            """
        ).all(decoding: Released.self)
        // 그 주 전에 나온 적이 있는 앱. 출시를 철회하면 출시 시각이 지워져서 알린 시각도 본다.
        struct AppIDRow: Decodable { var app_id: UUID }
        let earlier = Set(try await sql.raw(
            """
            SELECT DISTINCT app_id FROM versions
            WHERE released_at < \(bind: week.start) OR announced_at < \(bind: week.start)
            """
        ).all(decoding: AppIDRow.self).map(\.app_id))

        var seen = Set<UUID>()
        // 이름이 같은 사람이 둘일 수 있다. 사람은 ID 로 가른다.
        var newcomerIDs = Set<UUID>()
        for row in released where seen.insert(row.app_id).inserted {
            guard let app = byID[row.app_id], let ref = shared(row.app_id) else { continue }
            let release = Report.Release(app: ref, version: row.short_version, summary: app.summary)
            if earlier.contains(row.app_id) {
                report.updatedApps.append(release)
            } else {
                report.newApps.append(release)
                // 처음 앱을 낸 개발자: 그 사람의 다른 앱이 그 주 전에 나온 적이 없다.
                let ownerID = app.$owner.id
                let hasEarlier = byID.values.contains { other in
                    other.$owner.id == ownerID && other.id.map(earlier.contains) == true
                }
                if !hasEarlier, newcomerIDs.insert(ownerID).inserted {
                    report.newcomers.append(Report.Newcomer(name: app.owner.name, app: ref))
                }
            }
        }

        // 피드백과 별점
        struct CountRow: Decodable { var count: Int }
        report.feedbackCount = try await sql.raw(
            """
            SELECT COUNT(*) AS count FROM feedback
            WHERE created_at >= \(bind: week.start) AND created_at < \(bind: week.end)
              AND (\(bind: storeAppID)::uuid IS NULL OR app_id <> \(bind: storeAppID))
            """
        ).first(decoding: CountRow.self)?.count ?? 0

        // 평균은 누적이다. 한 주 별점만으로는 몇 명 되지 않는다. 다만 "별점이 높은 앱" 은
        // 그 주에 별점이 새로 들어온 앱 가운데서 고른다. 아니면 같은 앱이 매주 나온다.
        struct RatingRow: Decodable { var app_id: UUID; var average: Double; var count: Int; var recent: Int }
        let ratings = try await sql.raw(
            """
            SELECT app_id, AVG(rating)::float8 AS average, COUNT(rating) AS count,
              COUNT(rating) FILTER (WHERE created_at >= \(bind: week.start) AND created_at < \(bind: week.end)) AS recent
            FROM feedback
            WHERE rating IS NOT NULL GROUP BY app_id
            HAVING COUNT(rating) >= \(bind: ratingMinimumCount)
            """
        ).all(decoding: RatingRow.self)
        // 스토어 앱을 먼저 거른 뒤에 고른다. 거꾸로 하면 스토어 앱이 1위인 주에 아무것도 안 나온다.
        report.bestRated = ratings
            .filter { $0.average >= highRating && $0.recent > 0 }
            .sorted { ($0.average, $0.count) > ($1.average, $1.count) }
            .compactMap { row in shared(row.app_id).map { Report.Rated(app: $0, average: row.average, count: row.count) } }
            .first
        let lowRated = ratings
            .filter { $0.average <= lowRating }
            .sorted { $0.average < $1.average }
            .compactMap { row in console(row.app_id).map { Report.Rated(app: $0, average: row.average, count: row.count) } }
        report.lowRated = Array(lowRated.prefix(listLimit))
        report.lowRatedOverflow = max(0, lowRated.count - listLimit)

        // 서명 실패. 그 주에 끝난 잡 중 실패한 것을 갈래별로 센다.
        struct FailureRow: Decodable { var failure_code: String?; var count: Int }
        let failures = try await sql.raw(
            """
            SELECT j.failure_code, COUNT(*) AS count FROM signing_jobs j
            JOIN versions v ON v.id = j.version_id
            WHERE j.state = 'failed' AND j.finished_at >= \(bind: week.start) AND j.finished_at < \(bind: week.end)
              AND (\(bind: storeAppID)::uuid IS NULL OR v.app_id <> \(bind: storeAppID))
            GROUP BY j.failure_code ORDER BY count DESC
            """
        ).all(decoding: FailureRow.self)
        report.failureCount = failures.reduce(0) { $0 + $1.count }
        report.failuresByReason = failures.map { row in
            Report.ReasonCount(reason: Self.reasonName(row.failure_code), count: row.count)
        }

        // 해결되지 않은 서명 실패: 지금도 실패 상태이고, 같은 앱에 더 높은 빌드가 없다.
        struct UnresolvedRow: Decodable {
            var app_id: UUID; var short_version: String; var build_number: Int; var failure_code: String?
        }
        let unresolved = try await sql.raw(
            """
            SELECT v.app_id, v.short_version, v.build_number,
              (SELECT j.failure_code FROM signing_jobs j WHERE j.version_id = v.id
               ORDER BY j.created_at DESC LIMIT 1) AS failure_code
            FROM versions v
            WHERE v.state = 'failed'
              AND NOT EXISTS (
                SELECT 1 FROM versions newer
                WHERE newer.app_id = v.app_id AND newer.build_number > v.build_number
              )
            ORDER BY v.updated_at DESC
            """
        ).all(decoding: UnresolvedRow.self)
        let listed = unresolved.compactMap { row in
            console(row.app_id).map {
                Report.Failure(
                    app: $0,
                    version: "\(row.short_version) (\(row.build_number))",
                    reason: Self.reasonName(row.failure_code)
                )
            }
        }
        report.unresolved = Array(listed.prefix(listLimit))
        report.unresolvedOverflow = max(0, listed.count - listLimit)

        // 쉬고 있는 앱: 출시된 앱 중 오래 새 버전이 없거나 오래 받아간 사람이 없다.
        struct IdleRow: Decodable { var app_id: UUID; var last_release: Date; var recent: Int }
        let staleBefore = now.addingTimeInterval(-Double(staleReleaseDays) * 24 * 3600)
        let idleBefore = now.addingTimeInterval(-Double(idleDownloadDays) * 24 * 3600)
        let idle = try await sql.raw(
            """
            SELECT v.app_id, MAX(v.released_at) AS last_release,
              (SELECT COUNT(*) FROM downloads d JOIN versions dv ON dv.id = d.version_id
               WHERE dv.app_id = v.app_id AND d.created_at >= \(bind: idleBefore)) AS recent
            FROM versions v
            WHERE v.state = 'released' AND v.released_at IS NOT NULL
            GROUP BY v.app_id
            """
        ).all(decoding: IdleRow.self)
        let idleApps: [Report.Idle] = idle.compactMap { row in
            guard let ref = console(row.app_id) else { return nil }
            if row.last_release < staleBefore {
                return Report.Idle(app: ref, reason: "\(staleReleaseDays)일 넘게 새 버전이 없습니다")
            }
            // 나온 지 얼마 안 된 앱은 아직 받을 사람이 다 받지 않았다.
            if row.recent == 0, row.last_release < idleBefore {
                return Report.Idle(app: ref, reason: "\(idleDownloadDays)일 넘게 받아간 사람이 없습니다")
            }
            return nil
        }.sorted { $0.app.name < $1.app.name }
        report.idle = Array(idleApps.prefix(listLimit))
        report.idleOverflow = max(0, idleApps.count - listLimit)

        return report
    }

    private static func reasonName(_ code: String?) -> String {
        code.flatMap(SigningFailureCode.init(rawValue:)).map(SigningFailureGuidance.title)
            ?? SigningFailureGuidance.title(.unknown)
    }

    // MARK: - 쓰기

    /// 보낼 두 통. 운영 지표는 실을 것이 없으면 nil 이다.
    static func compose(_ report: Report) -> (newsletter: NotificationMessage, operations: NotificationMessage?) {
        typealias M = NotificationMarkup
        func link(_ app: Report.AppRef) -> String { M.link(app.link, app.name) }
        func delta(_ now: Int, _ before: Int) -> String {
            let change = now - before
            if change > 0 { return " ▲\(change)" }
            if change < 0 { return " ▼\(-change)" }
            return ""
        }

        let title = "📰 \(report.storeName) 주간 소식 (\(report.weekLabel))"
        var sections: [String] = []
        if report.isQuiet {
            sections.append("조용한 한 주였습니다. 새로 나온 앱도 받아간 사람도 없었습니다.")
        } else {
            sections.append(
                M.strong("📊 이번 주 숫자")
                    + "\n다운로드 \(report.downloads)회\(delta(report.downloads, report.previousDownloads))"
                    + " · 받아간 사람 \(report.people)명\(delta(report.people, report.previousPeople))"
            )
            if !report.newApps.isEmpty {
                sections.append(M.strong("🎉 새로 나온 앱") + report.newApps.map { release in
                    "\n• \(link(release.app)) \(release.version)" + (release.summary.map { " - \($0)" } ?? "")
                }.joined())
            }
            if !report.updatedApps.isEmpty {
                sections.append(
                    M.strong("✨ 업데이트된 앱") + "\n• "
                        + report.updatedApps.map { "\(link($0.app)) \($0.version)" }.joined(separator: " · ")
                )
            }
            if !report.top.isEmpty {
                sections.append(M.strong("🔥 많이 받은 앱") + report.top.enumerated().map { index, row in
                    "\n\(index + 1). \(link(row.app)) \(row.count)회"
                }.joined())
            }
            if !report.surging.isEmpty {
                sections.append(M.strong("📈 갑자기 많이 받은 앱") + report.surging.map { row in
                    let detail = row.previous == 0
                        ? "지난주 0회"
                        : "지난주 \(row.previous)회의 \(row.count / row.previous)배"
                    return "\n• \(link(row.app)) \(row.count)회 (\(detail))"
                }.joined())
            }
            if report.feedbackCount > 0 || report.bestRated != nil {
                var line = "새 피드백 \(report.feedbackCount)건"
                if let best = report.bestRated {
                    line += " · 별점이 높은 앱: \(link(best.app)) ★\(String(format: "%.1f", best.average)) (\(best.count)명)"
                }
                sections.append(M.strong("⭐ 별점과 피드백") + "\n" + line)
            }
            if !report.newcomers.isEmpty {
                sections.append(M.strong("👋 처음 앱을 낸 개발자") + report.newcomers.map {
                    "\n• \($0.name) - \(link($0.app))"
                }.joined())
            }
        }
        let newsletter = NotificationMessage(title: title, body: sections.joined(separator: "\n\n"))

        guard report.hasOperations else { return (newsletter, nil) }
        var ops: [String] = ["관리자에게만 보냅니다. 공용 채널에 전하지 마세요."]
        if report.failureCount > 0 || !report.unresolved.isEmpty {
            var text = M.strong("❗ 서명 실패 \(report.failureCount)건")
            if !report.failuresByReason.isEmpty {
                text += "\n" + report.failuresByReason.map { "\($0.reason) \($0.count)" }.joined(separator: " · ")
            }
            if !report.unresolved.isEmpty {
                text += "\n아직 해결되지 않은 것:" + report.unresolved.map {
                    "\n• \(link($0.app)) \($0.version) - \($0.reason)"
                }.joined()
                if report.unresolvedOverflow > 0 {
                    text += "\n외 \(report.unresolvedOverflow)건"
                }
            }
            ops.append(text)
        }
        func overflow(_ count: Int) -> String { count > 0 ? "\n외 \(count)개" : "" }
        if !report.lowRated.isEmpty {
            ops.append(M.strong("👎 별점이 낮은 앱") + report.lowRated.map {
                "\n• \(link($0.app)) ★\(String(format: "%.1f", $0.average)) (\($0.count)명)"
            }.joined() + overflow(report.lowRatedOverflow))
        }
        if !report.idle.isEmpty {
            ops.append(M.strong("💤 쉬고 있는 앱") + report.idle.map {
                "\n• \(link($0.app)) - \($0.reason)"
            }.joined() + overflow(report.idleOverflow))
        }
        let operations = NotificationMessage(
            title: "🛠 \(report.storeName) 운영 지표 (\(report.weekLabel))",
            body: ops.joined(separator: "\n\n")
        )
        return (newsletter, operations)
    }
}

/// 주간 소식을 보낸 주. 한 주에 한 번만 보내려고 둔다 (ADR-0076).
///
/// 서버가 여러 대여도 먼저 이 행을 넣은 쪽만 보낸다. 관리자마다 따로 적지 않는다. 한
/// 사람이 못 받았다고 다시 보내면 받은 사람에게 두 번 간다.
final class WeeklyDigestRun: Model, @unchecked Sendable {
    static let schema = "weekly_digests"

    @ID(custom: "week", generatedBy: .user)
    var id: String?

    @OptionalField(key: "sent_at")
    var sentAt: Date?

    init() {}
}

public struct CreateWeeklyDigestRun: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(WeeklyDigestRun.schema)
            .field("week", .string, .identifier(auto: false))
            .field("sent_at", .datetime)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(WeeklyDigestRun.schema).delete()
    }
}
