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

    static func run(on application: Application, now: Date = Date()) async {
        let database = application.db
        let logger = application.logger
        let notifier = Notifier(
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

        for token in soon {
            // 끊은 사람에게는 보내지 않는다. 그 토큰은 이미 쓸 수 없다 (ADR-0061).
            guard token.user.isActive else { continue }

            let days = max(1, Int(token.expiresAt.timeIntervalSince(now) / (24 * 3600)))
            await notifier.notify(
                person: token.user,
                message: NotificationMessage(
                    title: "토큰 '\(token.name)' 이 \(days)일 뒤 만료됩니다",
                    body: "내 설정 > 내 토큰에서 새로 발급하고 쓰던 곳의 값을 바꾸세요.",
                    link: baseURL + "/me/tokens"
                )
            )

            token.expiryNoticedAt = now
            do {
                try await token.save(on: database)
            } catch {
                // 저장에 실패하면 다음 번에 또 보낸다. 두 번 오는 것이 안 오는 것보다
                // 낫다.
                logger.error("토큰 만료 알림 기록에 실패했습니다: \(error)")
            }
        }

        if !soon.isEmpty {
            logger.notice("만료가 가까운 토큰 \(soon.count)개를 알렸습니다.")
        }
    }
}
