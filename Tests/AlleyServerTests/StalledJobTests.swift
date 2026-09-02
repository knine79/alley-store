import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

@Suite("멈춘 잡 판단")
struct StalledJobVerdictTests {
    private let now = Date()

    private func job(
        state: SigningJobState,
        attempt: Int = 1,
        heartbeat: Date? = nil,
        claimed: Date? = nil
    ) -> SigningJob {
        let job = SigningJob(versionID: UUID(), attempt: attempt)
        job.state = state
        job.heartbeatAt = heartbeat
        job.claimedAt = claimed
        return job
    }

    @Test("하트비트가 살아 있으면 멈춘 것이 아니다")
    func freshHeartbeatIsFine() {
        let fresh = job(state: .running, heartbeat: now.addingTimeInterval(-60))
        #expect(StalledJobSweep.verdict(for: fresh, now: now) == nil)
    }

    @Test("하트비트가 오래 끊기면 큐로 되돌린다")
    func staleHeartbeatIsRequeued() {
        // 워커는 30초마다 보낸다. 한 시간이면 서른 번 넘게 놓친 것이다.
        let stale = job(state: .running, heartbeat: now.addingTimeInterval(-3600))
        #expect(StalledJobSweep.verdict(for: stale, now: now) == .requeue)
    }

    @Test("하트비트가 한 번도 없으면 가져간 시각으로 본다")
    func fallsBackToClaimedAt() {
        // 잡을 받자마자 죽으면 하트비트가 한 번도 오지 않는다.
        let neverBeat = job(state: .running, claimed: now.addingTimeInterval(-3600))
        #expect(StalledJobSweep.verdict(for: neverBeat, now: now) == .requeue)
    }

    @Test("시도 상한을 넘기면 실패로 확정한다")
    func giveUpAtLimit() {
        let repeated = job(
            state: .running,
            attempt: StalledJobSweep.maximumAttempts,
            heartbeat: now.addingTimeInterval(-3600)
        )
        // 되돌리기만 하면 특정 빌드에서 죽는 워커가 큐를 무한히 돈다.
        #expect(StalledJobSweep.verdict(for: repeated, now: now) == .giveUp)
    }

    @Test("큐에서 기다리는 잡은 건드리지 않는다")
    func queuedJobIsIgnored() {
        let waiting = job(state: .queued, claimed: now.addingTimeInterval(-99999))
        #expect(StalledJobSweep.verdict(for: waiting, now: now) == nil)
    }

    @Test("이미 끝난 잡은 건드리지 않는다")
    func finishedJobIsIgnored() {
        let done = job(state: .succeeded, heartbeat: now.addingTimeInterval(-99999))
        #expect(StalledJobSweep.verdict(for: done, now: now) == nil)
    }
}

@Suite("멈춘 잡 회수")
struct StalledJobSweepTests {
    private let nextJobPath = "\(APIPath.nextJob)?timeout=0"

    /// 워커가 잡을 가져간 뒤 소식이 끊긴 상태를 만든다.
    private func stalledJob(
        on app: Application,
        attempt: Int = 1
    ) async throws -> (worker: Worker, token: String, version: Version, job: SigningJob) {
        let (worker, token) = try await app.makeWorker()
        let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: .uploaded, by: owner
        )
        try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

        var claimed: SigningJobDTO?
        try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) {
            claimed = try $0.content.decode(SigningJobDTO.self)
        }
        let ticket = try #require(claimed)
        let job = try #require(try await SigningJob.find(ticket.id, on: app.db))

        job.attempt = attempt
        job.heartbeatAt = Date().addingTimeInterval(-3600)
        try await job.save(on: app.db)

        worker.currentJobID = try job.requireID()
        try await worker.save(on: app.db)

        return (worker, token, version, job)
    }

    @Test("소식이 끊긴 잡을 큐로 되돌린다")
    func requeuesStalledJob() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (worker, _, version, job) = try await stalledJob(on: app)

            await StalledJobSweep.run(on: app)

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .queued)
            #expect(stored.$worker.id == nil)
            #expect(stored.heartbeatAt == nil)
            // 몇 번째 시도인지가 올라가야 무한 재시도를 막을 수 있다.
            #expect(stored.attempt == 2)

            // 버전은 그대로 둔다. signing 은 워커가 다시 가져갈 수 있는 상태다.
            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .signing)

            // 돌아오지 않는 워커가 계속 "작업 중"으로 보이면 안 된다.
            let storedWorker = try #require(try await Worker.find(try worker.requireID(), on: app.db))
            #expect(storedWorker.currentJobID == nil)
        }
    }

    @Test("되돌린 잡은 다음 워커가 가져간다")
    func requeuedJobIsHandedOutAgain() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            _ = try await stalledJob(on: app)
            let (_, token) = try await app.makeWorker(name: "살아 있는 워커")

            await StalledJobSweep.run(on: app)

            // 되돌리기의 목적은 이것뿐이다. 큐에 돌아온 잡이 실제로 다시 나가야 한다.
            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test("시도 상한을 넘기면 버전까지 실패로 확정한다")
    func giveUpFailsVersion() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, _, version, job) = try await stalledJob(
                on: app, attempt: StalledJobSweep.maximumAttempts
            )

            await StalledJobSweep.run(on: app)

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .failed)
            #expect(stored.failureReason != nil)

            // 실패로 확정해야 올린 사람이 다시 올려 되살릴 수 있다.
            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .failed)
            #expect(storedVersion.failureReason != nil)
        }
    }

    @Test("살아 있는 잡은 건드리지 않는다")
    func leavesLiveJobAlone() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, _, _, job) = try await stalledJob(on: app)
            job.heartbeatAt = Date()
            try await job.save(on: app.db)

            await StalledJobSweep.run(on: app)

            // 공증은 원래 오래 걸린다. 그 사이에 되돌리면 같은 버전을 두 번 제출한다.
            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .running)
            #expect(stored.attempt == 1)
        }
    }

    @Test("되돌린 잡을 옛 워커가 계속 보고할 수 없다")
    func oldWorkerCannotReportAfterRequeue() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, token, _, job) = try await stalledJob(on: app)

            await StalledJobSweep.run(on: app)

            // 네트워크만 끊겼다가 돌아온 워커가 남의 잡 결과를 덮어쓰면 안 된다.
            try await app.testing().test(
                .PATCH, "\(APIPath.workerRoot)/jobs/\(try job.requireID().uuidString)",
                headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(SigningJobUpdate(state: .succeeded))
                }
            ) { #expect($0.status == .forbidden) }
        }
    }
}
