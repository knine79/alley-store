import Fluent
import Foundation
import Vapor

/// 만료가 가까운 사람 토큰을 미리 알린다 (ADR-0060).
///
/// **만료는 조용히 온다.** 90일 뒤 어느 날 에이전트가 401 을 받기 시작하고, 받는
/// 사람은 그것이 만료인지 스토어가 죽은 것인지 모른다. 미리 한 줄 보내면 그 자리에서
/// 새로 발급하면 된다.
///
/// 한 번만 보낸다. 쓸고 지나갈 때마다 보내면 마지막 이레 동안 매번 온다.
enum UserTokenExpiryNotice {
    /// 얼마나 자주 볼지. 만료는 급하지 않아서 자주 볼 이유가 없다.
    static let checkInterval: Duration = .seconds(6 * 3600)

    /// `notifier` 는 시험이 넣는다. 실제로 보냈는지가 이 쓸기의 전부라, 아무 데도
    /// 가지 않는 상태로 돌리면 그 부분을 확인할 수 없다.
    static func run(
        on application: Application,
        now: Date = Date(),
        notifier: Notifier? = nil
    ) async {
        let database = application.db
        let logger = application.logger
        let notifier = notifier ?? Notifier(
            database: database,
            channels: application.notificationChannels,
            logger: logger
        )
        let baseURL = application.alleyConfig.publicBaseURL.trimmingSuffix("/")

        let deadline = now.addingTimeInterval(UserToken.noticeWindow)
        let soon: [UserToken]
        do {
            soon = try await UserToken.query(on: database)
                .filter(\.$revokedAt == nil)
                .filter(\.$expiryNoticedAt == nil)
                // 이미 만료된 것은 알리지 않는다. 그때는 401 이 곧 안내다.
                .filter(\.$expiresAt > now)
                .filter(\.$expiresAt <= deadline)
                .with(\.$user)
                .all()
        } catch {
            logger.error("만료가 가까운 토큰을 읽지 못했습니다: \(error)")
            return
        }

        var notified = 0
        var unreachable = 0
        for token in soon {
            // 끊은 사람에게는 보내지 않는다. 그 토큰은 이미 쓸 수 없다 (ADR-0061).
            guard token.user.isActive else { continue }

            let days = max(1, Int(token.expiresAt.timeIntervalSince(now) / (24 * 3600)))
            let delivered = await notifier.notify(
                person: token.user,
                message: NotificationMessage(
                    title: "토큰 '\(token.name)' 이 \(days)일 뒤 만료됩니다",
                    body: "내 설정 > 내 토큰에서 새로 발급하고 쓰던 곳의 값을 바꾸세요.",
                    link: baseURL + "/me/tokens"
                )
            )

            // **보낸 것만 보냈다고 적는다.** 스토어에 Slack 도 메일도 없으면 아무 데도
            // 가지 않는데, 그때 기록만 남기면 이 토큰은 다시는 여기 걸리지 않는다.
            // 관리자가 이틀 뒤 메일을 붙여도 그 사람은 끝까지 못 듣는다.
            guard delivered else {
                unreachable += 1
                continue
            }

            notified += 1
            token.expiryNoticedAt = now
            do {
                try await token.save(on: database)
            } catch {
                // 저장에 실패하면 다음 번에 또 보낸다. 두 번 오는 것이 안 오는 것보다
                // 낫다.
                logger.error("토큰 만료 알림 기록에 실패했습니다: \(error)")
            }
        }

        if notified > 0 {
            logger.notice("만료가 가까운 토큰 \(notified)개를 알렸습니다.")
        }
        if unreachable > 0 {
            logger.notice(
                "만료가 가까운데 닿을 길이 없는 토큰 \(unreachable)개입니다. 알림 수단을 확인하세요."
            )
        }
    }
}
