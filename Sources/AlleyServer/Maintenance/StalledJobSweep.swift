import AlleyShared
import Fluent
import Foundation
import Vapor

/// 워커가 죽어 `running` 에 멈춰 있는 서명 잡을 되돌린다.
///
/// 잡을 가져간 워커가 죽으면 그 잡은 아무도 손대지 않는 채로 남는다. 올린 사람은
/// "서명 중"을 계속 보고, 큐의 뒤에 있는 잡은 그것과 무관하게 나가지만 그 버전은
/// 영원히 끝나지 않는다. 지금까지는 사람이 데이터베이스를 고쳐야 했다 (ADR-0013).
///
/// 되돌린 잡의 버전 상태는 건드리지 않는다. `signing` 과 `notarizing` 은 워커가
/// 다시 가져갈 수 있는 상태다(`WorkerController.claimJob`). 억지로 `uploaded` 로
/// 끌어내리면 상태 머신이 허용하지 않는 전이가 된다.
public enum StalledJobSweep {
    /// 이 시간 넘게 소식이 없으면 잡을 잡고 있던 워커가 죽은 것으로 본다.
    ///
    /// 워커는 잡을 처리하는 내내 30초마다 하트비트를 보낸다(`WorkerLoop`). 공증처럼
    /// 오래 걸리는 단계에서도 마찬가지다. 그래서 15분은 하트비트 서른 번을 놓친
    /// 상황이다. 워커 감시(10분)보다 길게 잡은 이유는 대가가 다르기 때문이다.
    /// 워커 알림은 잘못 울려도 사람이 한 번 확인하면 끝이지만, 잡을 잘못 되돌리면
    /// 같은 버전을 두 번 공증 제출하게 된다.
    static let stallThreshold: TimeInterval = 15 * 60
    /// 확인 주기.
    static let checkInterval: Duration = .seconds(300)
    /// 같은 잡을 몇 번까지 내보낼지.
    ///
    /// 되돌리기만 하면 워커가 특정 빌드에서 죽는 경우에 큐를 무한히 도는 잡이 생긴다.
    /// 세 번이면 "저 워커 한 대가 그때 재부팅됐다" 정도의 우연은 넘어가고, 매번 죽는
    /// 빌드는 사람에게 넘어간다.
    static let maximumAttempts = 3

    /// 멈춘 잡을 어떻게 할 것인가.
    enum Verdict: Equatable {
        /// 큐로 되돌린다. 다음 워커가 가져간다.
        case requeue
        /// 시도 상한을 넘겼다. 실패로 확정하고 사람에게 넘긴다.
        case giveUp
    }

    /// 이 잡이 멈춘 것인지, 멈췄다면 어떻게 할 것인지.
    ///
    /// 시각을 인자로 받는 순수 함수로 둔다. "15분 전에 하트비트가 끊긴 잡"을
    /// 데이터베이스와 시계 없이 확인할 수 있어야 한다.
    static func verdict(for job: SigningJob, now: Date) -> Verdict? {
        // 큐에서 기다리거나 이미 끝난 잡은 멈춘 것이 아니다.
        guard job.state == .running else { return nil }

        // 하트비트가 없으면 가져간 시각을 쓴다. 워커가 잡을 받자마자 죽으면
        // 하트비트가 한 번도 오지 않는다.
        guard let lastSign = job.heartbeatAt ?? job.claimedAt ?? job.createdAt else { return nil }
        guard now.timeIntervalSince(lastSign) > stallThreshold else { return nil }

        return job.attempt >= maximumAttempts ? .giveUp : .requeue
    }

    /// 멈춘 잡을 한 번 훑는다.
    static func run(on application: Application, now: Date = Date()) async {
        let database = application.db
        let logger = application.logger

        let running = (try? await SigningJob.query(on: database)
            .filter(\.$state == .running)
            .with(\.$version)
            .all()) ?? []

        for job in running {
            guard let verdict = verdict(for: job, now: now) else { continue }
            let jobID = (try? job.requireID())?.uuidString ?? "?"
            let claimedBy = job.$worker.id

            switch verdict {
            case .requeue:
                job.attempt += 1
                job.state = .queued
                job.$worker.id = nil
                job.claimedAt = nil
                job.heartbeatAt = nil
                job.phase = nil
                // 올린 사람이 보는 곳에도 남긴다. 버전 상세의 로그가 워커가 남긴
                // 마지막 줄에서 멈춰 있으면 왜 다시 서명 중인지 알 수 없다.
                job.log = appending(
                    "워커 응답이 끊겨 잡을 큐로 되돌렸습니다. 시도 \(job.attempt) 회차로 다시 나갑니다.",
                    to: job.log
                )
                logger.warning("멈춘 서명 잡을 큐로 되돌립니다 [잡: \(jobID), 시도: \(job.attempt)]")

            case .giveUp:
                let reason = "워커가 \(job.attempt) 번 가져갔지만 끝내지 못했습니다. 서명 워커 상태를 확인하세요."
                job.state = .failed
                job.failureReason = reason
                job.finishedAt = now
                job.phase = nil
                // 버전도 실패로 확정한다. 그래야 올린 사람이 다시 올려 되살릴 수 있다.
                if job.version.state.canTransition(to: .failed) {
                    try? job.version.transition(to: .failed, reason: reason)
                    try? await job.version.save(on: database)
                }
                logger.error("서명 잡을 포기합니다 [잡: \(jobID), 시도: \(job.attempt)]")
            }

            try? await job.save(on: database)
            await releaseWorker(claimedBy, from: job, on: database)
        }
    }

    /// 죽은 워커가 이 잡을 붙들고 있다는 표시를 지운다.
    ///
    /// 관리 화면이 이 값으로 "작업 중"을 판단한다. 그대로 두면 돌아오지 않는 워커가
    /// 영영 작업 중으로 보인다.
    private static func releaseWorker(
        _ workerID: UUID?,
        from job: SigningJob,
        on database: any Database
    ) async {
        guard let workerID, let jobID = try? job.requireID() else { return }
        guard let worker = try? await Worker.find(workerID, on: database) else { return }
        guard worker.currentJobID == jobID else { return }

        worker.currentJobID = nil
        try? await worker.save(on: database)
    }

    private static func appending(_ note: String, to log: String?) -> String {
        guard let log, !log.isEmpty else { return note }
        return log + "\n" + note
    }
}
