import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 에이전트가 읽어갈 경로 (ADR-0060).
///
/// 화면에만 있던 것을 API 로도 낸다. 확인할 것은 두 가지다. 화면과 같은 답을
/// 주는가, 그리고 볼 수 없는 사람에게 막히는가.
@Suite("에이전트 API")
struct AgentAPITests {
    // MARK: - 서명 상태

    @Test("실패한 버전은 갈래와 할 일을 함께 준다")
    func failedVersionCarriesGuidance() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.signing", name: "서명앱", owner: owner
            )
            let appID = try registered.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .failed, by: owner
            )
            let versionID = try version.requireID()
            version.failureReason = "entitlements 가 없습니다"
            try await version.save(on: app.db)

            let job = SigningJob(versionID: versionID, attempt: 2)
            job.state = .failed
            job.failureCode = .entitlementsRejected
            try await job.save(on: app.db)

            let token = try await app.makeUserToken(for: owner)
            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: versionID), headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let status = try response.content.decode(SigningStatusDTO.self)
                #expect(status.failureCode == .entitlementsRejected)
                #expect(status.attempt == 2)
                // 버전에 남은 이유를 먼저 본다. 잡의 것으로 바꿔 쓰면 화면과 갈린다.
                #expect(status.failureReason == "entitlements 가 없습니다")
                // 화면용 한 문장이 아니라 무엇을 어떻게 하면 되는지가 와야 한다.
                #expect(status.whatToDo?.contains("upload_version") == true)
            }
        }
    }

    /// 일시적 실패는 서버가 큐로 되돌려 다시 시도한다 (ADR-0018). 그때 갈래를 그대로
    /// 내주면 에이전트가 아직 서명 중인 버전을 고치겠다고 파일을 다시 올린다.
    @Test("다시 시도 중인 것은 실패로 말하지 않는다")
    func retryInFlightIsNotAFailure() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.retry", name: "재시도앱", owner: owner
            )
            // 버전은 아직 서명 중이다. 잡에는 앞선 시도의 갈래가 남아 있다.
            let version = try await app.seedVersion(
                appID: try registered.requireID(), short: "1.0.0", build: 1,
                state: .signing, by: owner
            )
            let job = SigningJob(versionID: try version.requireID())
            job.state = .queued
            job.failureCode = .transferFailed
            job.failureReason = "옮기다 끊겼습니다"
            try await job.save(on: app.db)

            let token = try await app.makeUserToken(for: owner)
            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: try version.requireID()),
                headers: .bearer(token)
            ) { response in
                let status = try response.content.decode(SigningStatusDTO.self)
                #expect(status.state == .signing)
                #expect(status.failureCode == nil)
                #expect(status.whatToDo == nil)
            }
        }
    }

    @Test("올릴 수 없는 사람에게는 서명 상태를 보여주지 않는다")
    func signingStatusIsForUploaders() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (stranger, _) = try await app.makeUser(
                email: "stranger@example.com", role: .developer
            )
            let registered = try await app.seedApp(
                bundleID: "com.example.secret", name: "남의앱", owner: owner
            )
            let version = try await app.seedVersion(
                appID: try registered.requireID(), short: "1.0.0", build: 1,
                state: .failed, by: owner
            )

            let token = try await app.makeUserToken(for: stranger)
            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: try version.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - Sparkle

    /// 이 경로는 업로드 권한 기준이다. 그 앱과 아무 관계없는 사람에게는 닫혀야 한다.
    @Test("남의 앱의 Sparkle 상태는 볼 수 없다")
    func sparkleIsForUploaders() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (stranger, _) = try await app.makeUser(
                email: "stranger@example.com", role: .developer
            )
            let registered = try await app.seedApp(
                bundleID: "com.example.closed", name: "남의앱", owner: owner
            )

            let token = try await app.makeUserToken(for: stranger)
            try await app.testing().test(
                .GET, APIPath.sparkleFeedStatus(ofApp: try registered.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// 멤버는 올릴 수 있으니 자기가 올린 앱의 공개키를 봐야 한다.
    @Test("앱 멤버도 Sparkle 상태를 본다")
    func sparkleIsOpenToMembers() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.shared", name: "같이앱", owner: owner
            )
            try await AppMember(
                appID: try registered.requireID(), userID: try mate.requireID()
            ).save(on: app.db)

            let token = try await app.makeUserToken(for: mate)
            try await app.testing().test(
                .GET, APIPath.sparkleFeedStatus(ofApp: try registered.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("워커에 키가 없으면 공개키 대신 막힌 이유를 준다")
    func sparkleTellsWhatIsMissing() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.sparkle", name: "스파클앱", owner: owner
            )
            _ = try await app.makeWorker(name: "키 없는 워커")

            let token = try await app.makeUserToken(for: owner)
            try await app.testing().test(
                .GET, APIPath.sparkleFeedStatus(ofApp: try registered.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let feed = try response.content.decode(SparkleFeedDTO.self)
                #expect(feed.publicKey == nil)
                #expect(!feed.canIssue)
                // 문구가 아니라 갈래로 갈릴 수 있어야 한다.
                #expect(feed.readiness == .noKey)
                #expect(feed.note?.isEmpty == false)
            }
        }
    }

    /// 화면이 내주는 값과 같아야 한다. 갈리면 에이전트가 넣은 키로 업데이트가
    /// 안 되는데 화면은 된다고 말한다.
    @Test("워커가 알린 공개키를 그대로 준다")
    func sparkleReturnsThePublicKey() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.keyed", name: "키앱", owner: owner
            )
            let (worker, _) = try await app.makeWorker(name: "키 있는 워커")
            worker.sparklePublicKey = "pMju7cPB99HeZ1e9J2PKZ4jEde3yTxUWFOm8u/MkcWs="
            try await worker.save(on: app.db)

            let token = try await app.makeUserToken(for: owner)
            try await app.testing().test(
                .GET, APIPath.sparkleFeedStatus(ofApp: try registered.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let feed = try response.content.decode(SparkleFeedDTO.self)
                #expect(feed.publicKey == "pMju7cPB99HeZ1e9J2PKZ4jEde3yTxUWFOm8u/MkcWs=")
                #expect(feed.readiness == .ready)
                #expect(feed.canIssue)
                #expect(feed.issuedFeedCount == 0)
            }
        }
    }
}
