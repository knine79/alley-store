import AlleyShared
import Foundation

/// 잡을 기다렸다 처리하고 다시 기다리는 것을 반복한다.
///
/// 워커의 수명은 이 루프가 전부다. `launchd` 가 프로세스를 살려두고, 이 루프가
/// 서버를 계속 두드린다.
public struct WorkerLoop: Sendable {
    /// 하트비트 간격. 서버가 워커를 죽었다고 판단하기 전에 충분히 자주 보낸다.
    static let heartbeatInterval: Duration = .seconds(30)
    /// 서버에 연결하지 못했을 때 다시 시도하기까지 기다리는 시간.
    ///
    /// 서버가 재시작 중일 수 있다. 곧장 다시 두드리면 로그만 채운다.
    static let retryDelay: Duration = .seconds(10)

    private let config: WorkerConfig
    private let client: WorkerClient
    private let log: @Sendable (String) -> Void

    public init(config: WorkerConfig, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.config = config
        self.client = WorkerClient(config: config)
        self.log = log
    }

    /// 멈출 때까지 돈다.
    ///
    /// 예외로 빠져나오지 않는다. 서버가 죽었든 잡 하나가 실패했든 다음 잡을 계속
    /// 기다려야 한다. 워커가 조용히 종료되면 아무도 모르는 사이에 큐가 쌓인다.
    public func run() async {
        log("워커 '\(config.name)' 시작. 서버: \(config.serverURL.absoluteString)")
        await beat(currentJobID: nil)

        while !Task.isCancelled {
            do {
                guard let job = try await client.nextJob() else { continue }
                log("잡 \(job.id) 를 받았습니다. 버전: \(job.versionID)")
                await process(job)
            } catch {
                log("서버와 통신하지 못했습니다: \(error). \(Self.retryDelay) 뒤에 다시 시도합니다.")
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    /// 잡 하나를 처리하고 결과를 보고한다.
    ///
    /// 실패해도 던지지 않는다. 실패는 서버에 보고할 사실이지 루프를 끝낼 이유가 아니다.
    private func process(_ job: SigningJobDTO) async {
        let heartbeat = Task { await beatWhileRunning(jobID: job.id) }
        defer { heartbeat.cancel() }

        let pipeline = SigningPipeline(config: config) { phase, detail in
            log("[\(job.id)] \(phase.displayName)\(detail.map { " — \($0)" } ?? "")")
            try? await client.report(
                SigningJobUpdate(state: .running, phase: phase, log: detail),
                for: job.id
            )
        }

        do {
            let output = try await pipeline.run(job: job, client: client)
            try await client.report(
                SigningJobUpdate(
                    state: .succeeded,
                    resultSHA256: output.sha256,
                    resultSize: output.size,
                    resultEdSignature: output.edSignature
                ),
                for: job.id
            )
            log("잡 \(job.id) 완료 (\(output.size) 바이트)")
        } catch {
            let reason = String(describing: error)
            log("잡 \(job.id) 실패: \(reason)")
            // 보고까지 실패하면 서버는 이 잡을 running 으로 알고 있게 된다.
            // 하트비트가 끊긴 잡을 되돌리는 것은 서버 쪽 후속 과제다 (ADR-0013).
            try? await client.report(
                SigningJobUpdate(state: .failed, log: reason, failureReason: summarize(reason)),
                for: job.id
            )
        }
    }

    /// 잡을 처리하는 동안 계속 살아 있다고 알린다.
    private func beatWhileRunning(jobID: UUID) async {
        while !Task.isCancelled {
            await beat(currentJobID: jobID)
            try? await Task.sleep(for: Self.heartbeatInterval)
        }
    }

    private func beat(currentJobID: UUID?) async {
        do {
            try await client.sendHeartbeat(
                WorkerHeartbeat(
                    workerName: config.name,
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    currentJobID: currentJobID
                )
            )
        } catch {
            // 하트비트는 놓쳐도 다음 것이 있다. 여기서 시끄럽게 굴 이유가 없다.
            log("하트비트를 보내지 못했습니다: \(error)")
        }
    }

    /// 화면에 한 줄로 뜰 실패 이유.
    ///
    /// 전체 로그는 따로 보낸다. 목록에서 읽을 것은 첫 줄이면 충분하다.
    private func summarize(_ reason: String) -> String {
        let firstLine = reason.split(separator: "\n").first.map(String.init) ?? reason
        return firstLine.count > 300 ? String(firstLine.prefix(300)) + "…" : firstLine
    }
}
