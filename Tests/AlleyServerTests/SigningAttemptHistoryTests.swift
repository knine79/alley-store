import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 서명 시도를 현재/지난으로 나눠 보여주는 것 (이슈 #85).
///
/// 핵심은 "재시도 중에 직전 실패가 현재처럼 섞여 보이지 않는다" 이다. 데이터가
/// 접히지 않고 시도별로 끊겨, 화면과 signing_status 가 같은 모델을 본다.
@Suite("서명 시도 이력")
struct SigningAttemptHistoryTests {
    /// 한 버전에 실패 잡 두 건을 만든다. 버전은 실패로 끝난 상태로 둔다.
    private func seedTwoFailures(
        on app: Application
    ) async throws -> (version: Version, token: String) {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: .failed, by: owner
        )
        let versionID = try version.requireID()

        for note in ["codesign 실패", "또 실패"] {
            let job = try await SigningJob.enqueue(versionID: versionID, on: app.db)
            job.state = .failed
            job.failureCode = .signingKeyInaccessible
            job.failureReason = "errSecInternalComponent"
            job.append(note, phase: .codesigning)
            try await job.save(on: app.db)
        }
        return (version, token)
    }

    @Test("시도는 시간순 1..N 으로 번호가 매겨지고 마지막이 현재다")
    func numbersAttemptsInOrder() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (version, _) = try await seedTwoFailures(on: app)

            let attempts = try await SigningJob.attempts(
                ofVersion: try version.requireID(), on: app.db
            )
            #expect(attempts.map(\.number) == [1, 2])
            #expect(attempts.allSatisfy { $0.state == .failed })

            let (current, past) = SigningJob.AttemptReport.split(attempts)
            #expect(current?.number == 2)
            // 지난 시도는 최근 것이 위로 온다.
            #expect(past.map(\.number) == [1])
        }
    }

    @Test("다시 시도하면 현재는 도는 시도가 되고 직전 실패는 지난 시도로 내려간다")
    func freshRetryHidesPriorFailure() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (version, _) = try await seedTwoFailures(on: app)
            let versionID = try version.requireID()

            // 다시 시도: 새 잡이 큐에 들어가고 버전은 다시 올라간 상태가 된다.
            version.state = .uploaded
            version.failureReason = nil
            try await version.save(on: app.db)
            _ = try await SigningJob.enqueue(versionID: versionID, on: app.db)

            let attempts = try await SigningJob.attempts(ofVersion: versionID, on: app.db)
            let (current, past) = SigningJob.AttemptReport.split(attempts)

            // 현재 시도는 도는 중이고 실패 갈래가 없다. 직전 실패는 지난 시도에만 있다.
            #expect(current?.number == 3)
            #expect(current?.isLive == true)
            #expect(current?.failureCode == nil)
            #expect(past.map(\.number) == [2, 1])
            #expect(past.first?.failureCode == SigningFailureCode.signingKeyInaccessible.rawValue)
        }
    }

    @Test("signing_status 는 현재와 지난 시도를 섞지 않는다")
    func signingStatusSeparatesCurrentAndPast() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (version, token) = try await seedTwoFailures(on: app)
            let versionID = try version.requireID()

            // 실패로 끝난 상태: 맨 위에 갈래가 오고, 시도 둘이 이력에 담긴다.
            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: versionID), headers: .bearer(token)
            ) {
                let dto = try $0.content.decode(SigningStatusDTO.self)
                #expect(dto.failureCode == .signingKeyInaccessible)
                #expect(dto.attempts.map(\.number) == [1, 2])
            }

            // 다시 시도: 도는 잡이 생기면 맨 위 갈래는 사라지고 지난 시도에만 남는다.
            version.state = .uploaded
            version.failureReason = nil
            try await version.save(on: app.db)
            _ = try await SigningJob.enqueue(versionID: versionID, on: app.db)

            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: versionID), headers: .bearer(token)
            ) {
                let dto = try $0.content.decode(SigningStatusDTO.self)
                // 현재는 도는 중이라 맨 위는 실패가 아니다.
                #expect(dto.failureCode == nil)
                #expect(dto.attempt == 3)
                #expect(dto.attempts.count == 3)
                // 지난 두 시도의 실패 갈래는 그대로 남고, 현재 시도만 비어 있다.
                #expect(dto.attempts.filter { $0.failureCode != nil }.count == 2)
                #expect(dto.attempts.last?.failureCode == nil)
            }
        }
    }
}
