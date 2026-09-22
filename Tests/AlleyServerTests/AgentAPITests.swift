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
    private func personToken(for user: User, on app: Application) async throws -> String {
        let value = UserToken.generateToken()
        try await UserToken(
            name: "에이전트",
            tokenHash: UserToken.hash(token: value),
            userID: try user.requireID(),
            expiresAt: Date().addingTimeInterval(UserToken.lifetime)
        ).save(on: app.db)
        return value
    }

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

            let token = try await personToken(for: owner, on: app)
            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: versionID), headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let status = try response.content.decode(SigningStatusDTO.self)
                #expect(status.failureCode == .entitlementsRejected)
                #expect(status.attempt == 2)
                // 에이전트가 읽고 스스로 고치라고 내주는 값이다.
                #expect(status.whatToDo?.isEmpty == false)
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

            let token = try await personToken(for: stranger, on: app)
            try await app.testing().test(
                .GET, APIPath.signingStatus(versionID: try version.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - Sparkle

    @Test("워커에 키가 없으면 공개키 대신 막힌 이유를 준다")
    func sparkleTellsWhatIsMissing() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.sparkle", name: "스파클앱", owner: owner
            )
            _ = try await app.makeWorker(name: "키 없는 워커")

            let token = try await personToken(for: owner, on: app)
            try await app.testing().test(
                .GET, APIPath.sparkleFeedStatus(ofApp: try registered.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let feed = try response.content.decode(SparkleFeedDTO.self)
                #expect(feed.publicKey == nil)
                #expect(!feed.canIssue)
                #expect(feed.blocker?.isEmpty == false)
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

            let token = try await personToken(for: owner, on: app)
            try await app.testing().test(
                .GET, APIPath.sparkleFeedStatus(ofApp: try registered.requireID()),
                headers: .bearer(token)
            ) { response in
                let feed = try response.content.decode(SparkleFeedDTO.self)
                #expect(feed.publicKey == "pMju7cPB99HeZ1e9J2PKZ4jEde3yTxUWFOm8u/MkcWs=")
                #expect(feed.canIssue)
                #expect(feed.issuedFeedCount == 0)
            }
        }
    }
}
