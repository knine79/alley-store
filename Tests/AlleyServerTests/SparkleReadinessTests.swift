import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// Sparkle 을 쓸 수 있는 상태인지 화면이 말해준다 (ADR-0057).
///
/// **피드가 내려와도 업데이트가 안 되는 상태가 있었다.** 워커에 키가 없으면 서명이
/// 실패하지 않고 그냥 빠지고, Sparkle 은 서명 없는 업데이트를 조용히 건너뛴다.
/// 화면은 "주소를 넣으세요" 라고만 적혀 있어서, 그대로 따라 하면 막힌다.
@Suite("Sparkle 준비 상태")
struct SparkleReadinessTests {
    /// 앱 하나와 출시본 하나. 서명 여부는 호출하는 쪽이 정한다.
    private func seed(
        on app: Application,
        edSignature: String?
    ) async throws -> (App, User, String) {
        let (owner, token) = try await app.makeUser(email: "owner@example.com", role: .developer)
        let record = try await app.seedApp(
            bundleID: "com.example.sparkle", name: "스파클앱", owner: owner
        )
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: .released, by: owner
        )
        app.useFakeStorage()
        let artifact = Artifact(
            versionID: try version.requireID(),
            kind: .signed,
            storageKey: "apps/test/\(try version.requireID().uuidString)/signed.zip",
            sha256: nil,
            fileSize: 10
        )
        artifact.edSignature = edSignature
        try await artifact.save(on: app.db)
        return (record, owner, token)
    }

    /// 워커가 키를 알려주면 앱 만드는 사람이 화면에서 바로 복사한다. 예전에는
    /// 개인키를 가진 워커 관리자를 찾아가야만 알 수 있었다.
    @Test("워커가 보고한 공개키를 화면이 알려준다")
    func showsThePublicKeyReportedByTheWorker() async throws {
        try await withMigratedApp { app in
            let (record, _, token) = try await seed(on: app, edSignature: "sig")
            let (worker, _) = try await app.makeWorker()
            worker.sparklePublicKey = "PUBKEYAAA="
            try await worker.save(on: app.db)

            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains("SUPublicEDKey"))
                #expect(html.contains("PUBKEYAAA="))
            }
        }
    }

    /// **키가 없으면 그 사실을 말한다.** 이것이 이번 변경의 핵심이다. 예전에는
    /// 피드 주소만 내주고 아무 말도 하지 않았다.
    @Test("워커에 키가 없으면 경고한다")
    func warnsWhenNoWorkerHasAKey() async throws {
        try await withMigratedApp { app in
            let (record, _, token) = try await seed(on: app, edSignature: nil)
            _ = try await app.makeWorker()

            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)",
                headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("Sparkle 키가 없습니다"))
                // 알려줄 공개키가 없으니 상자도 그리지 않는다.
                #expect(!html.contains("SUPublicEDKey"))
            }
        }
    }

    /// **워커마다 키가 다르면 같은 앱이 어느 워커에 걸렸느냐에 따라 갈린다.**
    /// 잡은 놀고 있는 워커가 집어가고, 앱은 공개키를 하나만 읽는다. 재현이 안 되는
    /// 종류라 화면이 먼저 잡아야 한다.
    @Test("워커들의 키가 다르면 그것을 짚는다")
    func warnsWhenWorkersDisagree() async throws {
        try await withMigratedApp { app in
            let (record, _, token) = try await seed(on: app, edSignature: "sig")

            let (first, _) = try await app.makeWorker(name: "amodei")
            first.sparklePublicKey = "AAA="
            try await first.save(on: app.db)

            let (second, _) = try await app.makeWorker(name: "cook")
            second.sparklePublicKey = "BBB="
            try await second.save(on: app.db)

            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)",
                headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("서로 다른 Sparkle 키"))
                // 어느 것이 맞는지 모르므로 하나를 골라 내놓지 않는다.
                #expect(!html.contains("SUPublicEDKey"))
            }
        }
    }

    /// 폐기된 워커는 더 이상 서명하지 않는다. 그 키가 달라도 지금 배포에 영향이 없다.
    @Test("폐기된 워커의 키는 세지 않는다")
    func revokedWorkersDoNotCount() async throws {
        try await withMigratedApp { app in
            let (record, _, token) = try await seed(on: app, edSignature: "sig")

            let (live, _) = try await app.makeWorker(name: "amodei")
            live.sparklePublicKey = "AAA="
            try await live.save(on: app.db)

            let (dead, _) = try await app.makeWorker(name: "cook")
            dead.sparklePublicKey = "BBB="
            dead.revokedAt = Date()
            try await dead.save(on: app.db)

            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)",
                headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(!html.contains("서로 다른 Sparkle 키"))
                #expect(html.contains("AAA="))
            }
        }
    }

    /// 키는 있는데 이미 나간 버전에 서명이 없는 경우다. 그 버전은 고칠 수 없고,
    /// 화면이 말해야 하는 것은 "다음 버전부터 붙는다" 다.
    @Test("출시본에 서명이 없으면 그것도 짚는다")
    func warnsWhenTheLatestReleaseIsUnsigned() async throws {
        try await withMigratedApp { app in
            let (record, _, token) = try await seed(on: app, edSignature: nil)
            let (worker, _) = try await app.makeWorker()
            worker.sparklePublicKey = "PUBKEYAAA="
            try await worker.save(on: app.db)

            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)",
                headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("최근 출시본에 Sparkle 서명이 없습니다"))
                // 키는 있으므로 알려는 준다. 다음 버전에 쓸 값이다.
                #expect(html.contains("PUBKEYAAA="))
            }
        }
    }

    /// 개인키는 서버에 오지 않는다. 하트비트가 나르는 것은 공개키뿐이다.
    @Test("하트비트가 공개키를 실어 나른다")
    func heartbeatCarriesThePublicKey() async throws {
        try await withMigratedApp { app in
            let (worker, workerToken) = try await app.makeWorker()

            try await app.testing().test(
                .POST, APIPath.workerHeartbeat,
                headers: .bearer(workerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        WorkerHeartbeat(
                            workerName: "amodei",
                            osVersion: "15.0",
                            sparklePublicKey: "PUBKEYAAA="
                        )
                    )
                }
            ) { #expect($0.status == .noContent) }

            let refreshed = try #require(try await Worker.find(try worker.requireID(), on: app.db))
            #expect(refreshed.sparklePublicKey == "PUBKEYAAA=")
        }
    }

    /// 키를 빼면 화면도 따라가야 한다. 한 번 받은 값을 붙들고 있으면 키를 뺀 워커가
    /// 여전히 서명하는 것처럼 보인다.
    @Test("키를 빼면 보고도 비워진다")
    func removingTheKeyClearsIt() async throws {
        try await withMigratedApp { app in
            let (worker, workerToken) = try await app.makeWorker()
            worker.sparklePublicKey = "PUBKEYAAA="
            try await worker.save(on: app.db)

            try await app.testing().test(
                .POST, APIPath.workerHeartbeat,
                headers: .bearer(workerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        WorkerHeartbeat(workerName: "amodei", osVersion: "15.0")
                    )
                }
            ) { #expect($0.status == .noContent) }

            let refreshed = try #require(try await Worker.find(try worker.requireID(), on: app.db))
            #expect(refreshed.sparklePublicKey == nil)
        }
    }
}
