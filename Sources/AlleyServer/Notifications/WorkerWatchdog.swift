import AlleyShared
import Fluent
import Foundation
import Vapor

/// 조용해진 워커를 찾아 알린다.
///
/// 워커가 죽으면 아무 일도 일어나지 않는다. 큐에 잡이 쌓이고, 올린 사람은 "서명 대기"
/// 를 계속 본다. 아무도 안 보고 있으면 며칠이 지나도 모른다. 그래서 서버가 주기적으로
/// 확인한다. 주기를 도는 것은 `PeriodicSweep` 이 맡는다.
public enum WorkerWatchdog {
    /// 이 시간 넘게 소식이 없으면 죽은 것으로 본다.
    ///
    /// 워커는 30초마다 하트비트를 보낸다(`WorkerLoop`). 10분이면 재시작이나 잠깐의
    /// 네트워크 문제로 오알림이 뜨지는 않는다.
    static let silenceThreshold: TimeInterval = 10 * 60
    /// 확인 주기.
    static let checkInterval: Duration = .seconds(300)

    /// 조용해진 워커를 찾아 한 번 알린다.
    ///
    /// 알린 워커는 표시해둔다. 5분마다 같은 말을 반복하면 아무도 안 읽게 된다.
    static func check(on application: Application, now: Date = Date()) async {
        let database = application.db
        let logger = application.logger

        let workers = (try? await Worker.query(on: database).all()) ?? []
        let silent = workers.filter { isSilent($0, now: now) }
        guard !silent.isEmpty else { return }

        let notifier = Notifier(
            database: database,
            channels: [SlackWebhookChannel(client: application.client)],
            logger: logger
        )

        for worker in silent {
            let last = worker.lastSeenAt.map { DateStyle.minute.string(from: $0) } ?? "한 번도 없음"
            logger.warning("워커가 조용합니다 [이름: \(worker.name), 마지막 접속: \(last)]")

            await notifier.notifyGlobal(
                message: NotificationMessage(
                    title: "서명 워커 '\(worker.name)' 가 조용합니다",
                    body: """
                        마지막 접속: \(last)
                        미서명으로 올라온 버전이 서명 대기에서 멈춰 있을 수 있습니다.
                        """,
                    link: application.alleyConfig.publicBaseURL.trimmingSuffix("/") + "/admin/workers"
                )
            )

            worker.alertedAt = now
            try? await worker.save(on: database)
        }
    }

    /// 소식이 끊겼고 아직 알리지 않은 워커인지.
    static func isSilent(_ worker: Worker, now: Date) -> Bool {
        // 폐기한 워커는 조용한 것이 정상이다.
        guard worker.isActive else { return false }

        guard let lastSeen = worker.lastSeenAt else {
            // 등록만 하고 한 번도 붙지 않은 워커. 설치가 덜 끝난 경우라 알릴 값이 있다.
            // 등록 직후에 바로 울리지 않도록 등록 시각을 기준으로 본다.
            let created = worker.createdAt ?? now
            return now.timeIntervalSince(created) > silenceThreshold && worker.alertedAt == nil
        }

        guard now.timeIntervalSince(lastSeen) > silenceThreshold else { return false }
        // 이미 알린 뒤로 다시 붙은 적이 없으면 또 알리지 않는다.
        guard let alerted = worker.alertedAt else { return true }
        return lastSeen > alerted
    }
}
