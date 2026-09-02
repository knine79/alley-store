import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 업로더가 함께 올린 entitlements 가 워커까지 그대로 가는지 (ADR-0020).
///
/// 미서명 업로드에는 읽어낼 기존 서명이 없다. 이것이 끊기면 워커는 권한 없이 서명하고,
/// 공증까지 통과한 뒤 사용자의 맥에서야 앱이 죽는다.
@Suite("버전 entitlements")
struct VersionEntitlementsTests {
    private let valid = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>com.apple.security.cs.allow-jit</key><true/></dict>
        </plist>
        """

    private func seedApp(on app: Application) async throws -> (appID: UUID, token: String) {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(
            bundleID: "com.example.tool", name: "도구", owner: owner
        )
        return (try record.requireID(), token)
    }

    private func createVersion(
        _ payload: CreateVersionRequest,
        appID: UUID,
        token: String,
        on app: Application,
        check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.testing().test(
            .POST, APIPath.versions(ofApp: appID), headers: .bearer(token),
            beforeRequest: { try $0.content.encode(payload) },
            afterResponse: check
        )
    }

    @Test("올린 entitlements 를 버전에 남긴다")
    func storesEntitlements() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedApp(on: app)

            var versionID: UUID?
            try await createVersion(
                CreateVersionRequest(
                    shortVersion: "1.0.0", buildNumber: 1, entitlements: valid
                ),
                appID: setup.appID, token: setup.token, on: app
            ) { response in
                #expect(response.status == .created)
                versionID = try response.content.decode(UploadTicket.self).version.id
            }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.entitlements == valid)
        }
    }

    @Test("안 보내도 만들어진다")
    func allowsMissingEntitlements() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedApp(on: app)

            // 대부분의 앱은 안 보낸다. 필수로 보면 그 앱들이 전부 막힌다.
            try await createVersion(
                CreateVersionRequest(shortVersion: "1.0.0", buildNumber: 1),
                appID: setup.appID, token: setup.token, on: app
            ) { #expect($0.status == .created) }
        }
    }

    @Test("깨진 plist 는 받는 자리에서 거절한다")
    func rejectsMalformedPlist() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedApp(on: app)

            // 서명할 때가 되어서야 발견하면 워커가 이미 잡을 물고 있다.
            try await createVersion(
                CreateVersionRequest(
                    shortVersion: "1.0.0", buildNumber: 1, entitlements: "plist 아님"
                ),
                appID: setup.appID, token: setup.token, on: app
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("너무 큰 plist 는 거절한다")
    func rejectsOversizedPlist() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedApp(on: app)

            try await createVersion(
                CreateVersionRequest(
                    shortVersion: "1.0.0",
                    buildNumber: 1,
                    entitlements: String(repeating: "가", count: EntitlementsPlist.maximumSize)
                ),
                appID: setup.appID, token: setup.token, on: app
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("서명 지시서에 실어 보낸다")
    func handsEntitlementsToWorker() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let version = try await app.seedVersion(
                appID: try record.requireID(),
                short: "1.0.0",
                build: 1,
                state: .uploaded,
                by: owner
            )
            version.entitlements = valid
            try await version.save(on: app.db)
            _ = try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

            let (_, workerToken) = try await app.makeWorker()
            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(workerToken)
            ) { response in
                #expect(response.status == .ok)
                let ticket = try response.content.decode(SigningJobDTO.self)
                #expect(ticket.entitlements == valid)
            }
        }
    }
}
