import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

@Suite("실패 갈래에 따른 재시도 판단")
struct SigningRetryPolicyTests {
    @Test("다시 해도 소용없는 갈래는 시도 횟수를 쓰지 않고 포기한다")
    func nonRetriableGivesUpImmediately() {
        // 만료된 인증서로 세 번 서명해봐야 세 배로 기다릴 뿐이다.
        #expect(
            SigningRetryPolicy.verdict(reported: .signingIdentityUnavailable, attempt: 1)
                == .giveUp
        )
    }

    @Test("다시 해볼 만한 갈래는 상한까지 되돌린다")
    func retriableRequeuesUntilLimit() {
        #expect(SigningRetryPolicy.verdict(reported: .transferFailed, attempt: 1) == .requeue)
        #expect(
            SigningRetryPolicy.verdict(
                reported: .transferFailed, attempt: SigningRetryPolicy.maximumAttempts
            ) == .giveUp
        )
    }

    @Test("분류하지 못한 실패는 되돌리지 않는다")
    func unknownGivesUp() {
        #expect(SigningRetryPolicy.verdict(reported: .unknown, attempt: 1) == .giveUp)
    }

    @Test("갈래가 없는 것과 분류하지 못한 것은 다르다")
    func silenceIsNotUnknown() {
        // 워커가 죽어서 아무 말도 못 한 잡은 예전처럼 시도 상한만 본다 (ADR-0018).
        #expect(SigningRetryPolicy.verdict(stalledAttempt: 1, lastReported: nil) == .requeue)
        // 워커가 "모르겠다"고 보고한 것은 다르다. 그건 되돌리지 않는다.
        #expect(SigningRetryPolicy.verdict(reported: .unknown, attempt: 1) == .giveUp)
        // 코드가 아예 없는 보고도 마찬가지다. 예전 워커이거나 서버가 판정한 실패다.
        #expect(SigningRetryPolicy.verdict(reported: nil, attempt: 1) == .giveUp)
    }
}

@Suite("잡 로그 쌓기")
struct SigningJobLogTests {
    private let time = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("단계가 바뀌어도 앞의 로그가 남는다")
    func appendsInsteadOfOverwriting() {
        let first = SigningJob.appending("서명 대상 12개", to: nil, phase: .codesigning, at: time)
        let second = SigningJob.appending("Apple 이 거절했습니다", to: first, phase: .notarizing, at: time)

        // 실패 원인을 찾을 때 정작 필요한 것은 그 직전 단계의 로그다.
        #expect(second.contains("서명 대상 12개"))
        #expect(second.contains("Apple 이 거절했습니다"))
        #expect(second.contains(SigningPhase.codesigning.displayName))
    }

    @Test("빈 로그는 붙이지 않는다")
    func skipsEmptyEntries() {
        #expect(SigningJob.appending("   \n ", to: "앞의 것", at: time) == "앞의 것")
    }

    @Test("상한을 넘으면 앞을 버린다")
    func keepsTheTail() {
        // 실패 원인은 거의 언제나 끝에 있다.
        let long = String(repeating: "가나다라\n", count: SigningJob.logLimit)
        let result = SigningJob.appending("마지막 줄", to: long, at: time)

        #expect(result.contains("마지막 줄"))
        #expect(result.count <= SigningJob.logLimit + 200)
        // 잘렸다는 사실이 남아야 앞부분이 원래 없었는지 잘렸는지 알 수 있다.
        #expect(result.hasPrefix("…앞부분"))
    }
}

@Suite("워커가 보고한 실패의 갈래")
struct ReportedFailureTests {
    private let nextJobPath = "\(APIPath.nextJob)?timeout=0"

    private func claimedJob(on app: Application) async throws -> (
        token: String, version: Version, job: SigningJob
    ) {
        let (_, token) = try await app.makeWorker()
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
        return (token, version, job)
    }

    private func report(
        _ update: SigningJobUpdate,
        for job: SigningJob,
        token: String,
        on app: Application
    ) async throws {
        try await app.testing().test(
            .PATCH, "\(APIPath.workerRoot)/jobs/\(try job.requireID().uuidString)",
            headers: .bearer(token),
            beforeRequest: { try $0.content.encode(update) }
        ) { #expect($0.status == .noContent) }
    }

    @Test("다시 해도 소용없는 실패는 곧장 실패로 확정한다")
    func nonRetriableFailsRightAway() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app)

            try await report(
                SigningJobUpdate(
                    state: .failed,
                    failureReason: "서명 identity 를 찾지 못했습니다.",
                    failureCode: .signingIdentityUnavailable
                ),
                for: job, token: token, on: app
            )

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .failed)
            #expect(stored.failureCode == .signingIdentityUnavailable)
            // 시도 횟수를 쓰지 않는다. 세 번 더 해도 같은 결과다.
            #expect(stored.attempt == 1)

            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .failed)
        }
    }

    @Test("일시적 실패는 큐로 되돌려 다시 내보낸다")
    func retriableGoesBackToQueue() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app)

            try await report(
                SigningJobUpdate(
                    state: .failed,
                    failureReason: "아티팩트를 내려받지 못했습니다.",
                    failureCode: .transferFailed
                ),
                for: job, token: token, on: app
            )

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .queued)
            #expect(stored.attempt == 2)
            #expect(stored.$worker.id == nil)

            // 버전은 건드리지 않는다. signing 은 워커가 다시 가져갈 수 있는 상태다.
            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .signing)

            // 되돌리기의 목적은 이것뿐이다. 다음 워커가 실제로 가져가야 한다.
            let (_, other) = try await app.makeWorker(name: "다음 워커")
            try await app.testing().test(.GET, nextJobPath, headers: .bearer(other)) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test("일시적 실패도 상한을 넘기면 포기한다")
    func retriableStopsAtTheLimit() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app)
            job.attempt = SigningRetryPolicy.maximumAttempts
            try await job.save(on: app.db)

            try await report(
                SigningJobUpdate(state: .failed, failureCode: .appleServiceUnavailable),
                for: job, token: token, on: app
            )

            // 무한히 도는 잡을 만들지 않는다. 상한은 멈춘 잡 회수와 함께 쓴다.
            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .failed)

            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .failed)
        }
    }

    @Test("모르는 코드는 되돌리지 않는다")
    func unknownCodeIsNotRequeued() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (token, _, job) = try await claimedJob(on: app)

            // 서버보다 새로운 워커가 보낸, 서버가 모르는 코드다.
            try await app.testing().test(
                .PATCH, "\(APIPath.workerRoot)/jobs/\(try job.requireID().uuidString)",
                headers: .bearer(token),
                beforeRequest: { request in
                    request.headers.contentType = .json
                    request.body = ByteBuffer(
                        string: #"{"state":"failed","failureCode":"code_from_the_future"}"#
                    )
                }
            ) { #expect($0.status == .noContent) }

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            // 보고 자체는 받아들이되, 모르는 것을 재시도하지는 않는다 (ADR-0023).
            #expect(stored.state == .failed)
            #expect(stored.failureCode == .unknown)
        }
    }

    @Test("단계마다 보고한 로그가 실패 뒤에도 남는다")
    func logsAccumulateAcrossPhases() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (token, _, job) = try await claimedJob(on: app)

            try await report(
                SigningJobUpdate(state: .running, phase: .validating, log: "번들: 도구.app"),
                for: job, token: token, on: app
            )
            try await report(
                SigningJobUpdate(state: .running, phase: .codesigning, log: "서명 대상 12개"),
                for: job, token: token, on: app
            )
            try await report(
                SigningJobUpdate(
                    state: .failed,
                    log: "codesign: 서명되지 않고 남은 코드가 있습니다",
                    failureCode: .unsignedCodeRemains
                ),
                for: job, token: token, on: app
            )

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            let log = try #require(stored.log)
            // 원인 파악에 가장 필요한 것은 실패 직전 단계의 로그다 (ADR-0023).
            #expect(log.contains("번들: 도구.app"))
            #expect(log.contains("서명 대상 12개"))
            #expect(log.contains("남은 코드가 있습니다"))
        }
    }
}
