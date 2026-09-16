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
    /// 새 워커가 나왔는지 확인하는 간격 (ADR-0042).
    ///
    /// 잡을 기다리는 long-poll 이 끝날 때마다 보면 25초마다 묻게 된다. 워커 릴리스는
    /// 몇 주에 한 번 있는 일이라 그만큼 자주 볼 이유가 없다.
    static let updateCheckInterval: Duration = .seconds(600)

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
        log("워커 '\(config.name)' \(WorkerVersion.current) 시작. 서버: \(config.serverURL.absoluteString)")
        await beat(currentJobID: nil)

        let updater = SelfUpdate(config: config, client: client, log: log)
        var nextUpdateCheck = ContinuousClock.now

        while !Task.isCancelled {
            do {
                // **잡을 받기 전에 본다.** 여기가 확실히 노는 순간이다. 잡을 처리한
                // 직후에 보면 다음 잡이 이미 큐에 있을 수 있고, 그 사이에 프로세스를
                // 끝내면 그 잡은 워커가 죽은 것으로 보인다.
                if ContinuousClock.now >= nextUpdateCheck {
                    nextUpdateCheck = ContinuousClock.now.advanced(by: Self.updateCheckInterval)
                    if await checkForUpdate(updater) { return }
                }

                guard let job = try await client.nextJob() else { continue }
                log("잡 \(job.id) 를 받았습니다. 버전: \(job.versionID)")
                await process(job)
            } catch {
                log("""
                    서버와 통신하지 못했습니다: \(error). \(Self.retryDelay) 뒤에 다시 시도합니다.\
                    \(Self.hint(for: error, pollTimeout: config.pollTimeout))
                    """)
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    /// 게이트웨이가 끊은 것으로 보이면 어디를 봐야 하는지 한 줄 덧붙인다.
    ///
    /// **이 실패는 서버 문제처럼 읽힌다.** 앞단 프록시의 타임아웃이 `pollTimeout`
    /// 보다 짧으면 큐가 빌 때마다 프록시가 먼저 끊고 502·504 를 준다. 잡이 있을
    /// 때는 곧바로 응답이 와서 서명은 멀쩡히 돌기 때문에, 로그만 보고 서버나
    /// 네트워크를 한참 뒤지게 된다.
    ///
    /// **조용히 넘기지는 않는다.** 게이트웨이가 정말 죽어서 나는 502·504 와 구분할
    /// 방법이 없다. 그것까지 감추면 진짜 장애가 안 보인다. 그래서 줄은 그대로 남기고
    /// 짚을 곳만 알려준다.
    static func hint(for error: any Error, pollTimeout: Int) -> String {
        guard case .badResponse(let status, _)? = error as? WorkerClient.ClientError,
              status == 502 || status == 504
        else {
            return ""
        }
        return """
             큐가 비었을 때만 이렇게 된다면 앞단 프록시가 먼저 끊은 것입니다. \
            ALLEY_POLL_TIMEOUT(지금 \(pollTimeout)초)을 프록시 타임아웃보다 짧게 잡으세요.
            """
    }

    /// 새 워커로 갈아끼웠으면 true. 그때 루프를 끝내야 한다.
    ///
    /// 끝내면 `launchd` 가 새 번들로 다시 띄운다. 여기서 `exit` 을 부르지 않는 이유는
    /// 테스트에서 프로세스를 죽이지 않고 이 판단만 확인할 수 있어야 하기 때문이다.
    private func checkForUpdate(_ updater: SelfUpdate) async -> Bool {
        switch await updater.runIfNeeded() {
        case .replaced(let version):
            log("워커 \(version) 로 갈아끼웠습니다. 프로세스를 끝냅니다. launchd 가 다시 띄웁니다.")
            return true
        case .upToDate:
            return false
        case .skipped(let reason):
            log("갈아끼우지 않았습니다: \(reason)")
            return false
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
                    resultEdSignature: output.edSignature,
                    bundleMetadata: output.bundleMetadata,
                    diskImageSHA256: output.diskImageSHA256,
                    diskImageSize: output.diskImageSize
                ),
                for: job.id
            )
            let dmg = output.diskImageSize.map { " + dmg \($0) 바이트" } ?? ""
            log("잡 \(job.id) 완료 (\(output.size) 바이트\(dmg))")
        } catch {
            let reason = String(describing: error)
            // 갈래를 여기서 정한다. 오류 타입을 손에 쥔 곳은 여기뿐이고, 서버가
            // 문자열을 다시 해석하게 두지 않는다 (ADR-0023).
            let code = SigningFailureCode.classify(error)
            log("잡 \(job.id) 실패 [\(code.rawValue)]: \(reason)")
            // 보고까지 실패하면 서버는 이 잡을 running 으로 알고 있게 된다.
            // 하트비트가 끊기면 서버가 그 잡을 큐로 되돌린다 (ADR-0018).
            try? await client.report(
                SigningJobUpdate(
                    state: .failed,
                    log: reason,
                    failureReason: summarize(reason),
                    failureCode: code
                ),
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
                    currentJobID: currentJobID,
                    workerVersion: WorkerVersion.current
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
