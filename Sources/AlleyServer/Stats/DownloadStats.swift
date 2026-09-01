import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 다운로드 집계.
///
/// **"설치"가 아니라 "다운로드"다.** 서버가 아는 것은 누군가 파일을 받아갔다는
/// 사실까지다. 그 사람이 실제로 설치했는지, 지금도 쓰고 있는지는 모른다. 화면에
/// "설치 수"라고 적으면 없는 것을 아는 척하게 된다.
///
/// 집계는 SQL 로 한다. Fluent 로 전부 읽어와 Swift 에서 세면 다운로드가 쌓일수록
/// 메모리와 시간이 같이 는다.
enum DownloadStats {
    /// 앱 하나의 다운로드 요약.
    struct AppSummary: Sendable {
        var total: Int
        /// 최근 30일.
        var recent: Int
        /// 한 번이라도 받아간 사람 수. 같은 사람이 여러 번 받아도 하나로 센다.
        var people: Int
    }

    /// 버전 하나의 다운로드 수.
    struct VersionCount: Sendable {
        var versionID: UUID
        var count: Int
    }

    /// 최근 며칠을 "최근"으로 볼지.
    static let recentDays = 30

    static func summary(
        ofApp appID: UUID,
        on database: any Database
    ) async throws -> AppSummary {
        guard let sql = database as? any SQLDatabase else {
            return AppSummary(total: 0, recent: 0, people: 0)
        }

        let row = try await sql.raw(
            """
            SELECT
                COUNT(*) AS total,
                COUNT(*) FILTER (
                    WHERE d.created_at > now() - INTERVAL '\(unsafeRaw: String(recentDays)) days'
                ) AS recent,
                COUNT(DISTINCT d.user_id) AS people
              FROM downloads d
              JOIN versions v ON v.id = d.version_id
             WHERE v.app_id = \(bind: appID)
            """
        ).first()

        guard let row else { return AppSummary(total: 0, recent: 0, people: 0) }
        return AppSummary(
            total: (try? row.decode(column: "total", as: Int.self)) ?? 0,
            recent: (try? row.decode(column: "recent", as: Int.self)) ?? 0,
            people: (try? row.decode(column: "people", as: Int.self)) ?? 0
        )
    }

    /// 앱 하나의 버전별 다운로드 수.
    static func perVersion(
        ofApp appID: UUID,
        on database: any Database
    ) async throws -> [UUID: Int] {
        guard let sql = database as? any SQLDatabase else { return [:] }

        let rows = try await sql.raw(
            """
            SELECT d.version_id AS version_id, COUNT(*) AS count
              FROM downloads d
              JOIN versions v ON v.id = d.version_id
             WHERE v.app_id = \(bind: appID)
             GROUP BY d.version_id
            """
        ).all()

        return rows.reduce(into: [:]) { result, row in
            guard let id = try? row.decode(column: "version_id", as: UUID.self),
                  let count = try? row.decode(column: "count", as: Int.self)
            else {
                return
            }
            result[id] = count
        }
    }

    /// 스토어 전체 현황. 관리자 화면이 쓴다.
    struct StoreOverview: Sendable {
        struct Row: Sendable {
            var appID: UUID
            var appName: String
            var bundleID: String
            var total: Int
            var recent: Int
            var people: Int
        }

        var rows: [Row]
        /// 한 번이라도 무언가를 받아간 사람 수.
        var activePeople: Int
        var totalDownloads: Int
        var recentDownloads: Int
    }

    static func overview(on database: any Database) async throws -> StoreOverview {
        guard let sql = database as? any SQLDatabase else {
            return StoreOverview(rows: [], activePeople: 0, totalDownloads: 0, recentDownloads: 0)
        }

        // 다운로드가 없는 앱도 0 으로 나와야 한다. 목록에서 사라지면 "아무도 안 받는
        // 앱"이 보이지 않고, 그게 가장 알고 싶은 것 중 하나다.
        let rows = try await sql.raw(
            """
            SELECT
                a.id AS app_id,
                a.name AS app_name,
                a.bundle_id AS bundle_id,
                COUNT(d.id) AS total,
                COUNT(d.id) FILTER (
                    WHERE d.created_at > now() - INTERVAL '\(unsafeRaw: String(recentDays)) days'
                ) AS recent,
                COUNT(DISTINCT d.user_id) AS people
              FROM apps a
              LEFT JOIN versions v ON v.app_id = a.id
              LEFT JOIN downloads d ON d.version_id = v.id
             GROUP BY a.id, a.name, a.bundle_id
             ORDER BY total DESC, a.name
            """
        ).all()

        let parsed: [StoreOverview.Row] = rows.compactMap { row in
            guard let id = try? row.decode(column: "app_id", as: UUID.self),
                  let name = try? row.decode(column: "app_name", as: String.self),
                  let bundleID = try? row.decode(column: "bundle_id", as: String.self)
            else {
                return nil
            }
            return StoreOverview.Row(
                appID: id,
                appName: name,
                bundleID: bundleID,
                total: (try? row.decode(column: "total", as: Int.self)) ?? 0,
                recent: (try? row.decode(column: "recent", as: Int.self)) ?? 0,
                people: (try? row.decode(column: "people", as: Int.self)) ?? 0
            )
        }

        let totals = try await sql.raw(
            """
            SELECT
                COUNT(*) AS total,
                COUNT(*) FILTER (
                    WHERE created_at > now() - INTERVAL '\(unsafeRaw: String(recentDays)) days'
                ) AS recent,
                COUNT(DISTINCT user_id) AS people
              FROM downloads
            """
        ).first()

        return StoreOverview(
            rows: parsed,
            activePeople: (try? totals?.decode(column: "people", as: Int.self)) ?? 0,
            totalDownloads: (try? totals?.decode(column: "total", as: Int.self)) ?? 0,
            recentDownloads: (try? totals?.decode(column: "recent", as: Int.self)) ?? 0
        )
    }
}
