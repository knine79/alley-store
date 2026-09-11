import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 워커 릴리스를 받아 배포한다 (ADR-0042).
///
/// 워커를 고쳐도 사람이 각 맥에 가서 다시 설치해야 했다. 그래서 dmg 를 모르는
/// 워커가 한참 돌면서 dmg 를 zip 으로 풀다 엉뚱한 진단을 내놨다.
@Suite("워커 릴리스")
struct WorkerReleaseTests {
    /// 최상위에 `.app` 이 있는 zip. 서버가 그것까지 확인한다 (ADR-0042).
    private static func zipBytes() -> Data {
        ZipFixture.workerBundle()
    }

    @Test("올리면 배포 중이 된다")
    func acceptsAndDeploys() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            let release = try await WorkerReleaseService.accept(
                version: "0.2.0",
                data: Self.zipBytes(),
                makeCurrent: true,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )

            #expect(release.isCurrent)
            #expect(release.fileSize == Int64(Self.zipBytes().count))
            // 행만 남기고 오브젝트를 안 올리면 워커가 404 나는 주소를 받는다.
            #expect(try await storage.head(key: release.storageKey)
                == Int64(Self.zipBytes().count))
            let current = try #require(try await WorkerRelease.current(on: app.db))
            #expect(current.version == "0.2.0")
        }
    }

    @Test("보관만 할 수도 있다")
    func canHoldWithoutDeploying() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            _ = try await WorkerReleaseService.accept(
                version: "0.3.0", data: Self.zipBytes(), makeCurrent: false,
                by: admin, storage: storage, on: app.db, logger: app.logger
            )
            #expect(try await WorkerRelease.current(on: app.db) == nil)
        }
    }

    /// **견줄 수 없는 버전은 받지 않는다.** 워커가 자기 것과 비교해서 판단하는데,
    /// 읽을 수 없는 값이면 그 비교가 조용히 "낡지 않았다" 로 떨어진다.
    @Test("견줄 수 없는 버전은 거절한다", arguments: ["", "nightly", "v0.2.0"])
    func rejectsUncomparableVersion(version: String) async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            await #expect(throws: Abort.self) {
                try await WorkerReleaseService.accept(
                    version: version, data: Self.zipBytes(), makeCurrent: true,
                    by: admin, storage: storage, on: app.db, logger: app.logger
                )
            }
        }
    }

    @Test("zip 이 아니면 거절한다")
    func rejectsNonZip() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            await #expect(throws: Abort.self) {
                try await WorkerReleaseService.accept(
                    version: "0.2.0", data: Data(repeating: 0x00, count: 64), makeCurrent: true,
                    by: admin, storage: storage, on: app.db, logger: app.logger
                )
            }
        }
    }

    @Test("같은 버전을 두 번 올릴 수 없다")
    func rejectsDuplicateVersion() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            _ = try await WorkerReleaseService.accept(
                version: "0.2.0", data: Self.zipBytes(), makeCurrent: true,
                by: admin, storage: storage, on: app.db, logger: app.logger
            )
            await #expect(throws: Abort.self) {
                try await WorkerReleaseService.accept(
                    version: "0.2.0", data: Self.zipBytes(), makeCurrent: true,
                    by: admin, storage: storage, on: app.db, logger: app.logger
                )
            }
        }
    }

    /// 새 워커에 문제가 있으면 옛 릴리스를 다시 배포로 만든다. 그것이 되돌리는 길이다.
    @Test("배포 중은 언제나 하나다")
    func onlyOneIsCurrent() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            let first = try await WorkerReleaseService.accept(
                version: "0.2.0", data: Self.zipBytes(), makeCurrent: true,
                by: admin, storage: storage, on: app.db, logger: app.logger
            )
            let second = try await WorkerReleaseService.accept(
                version: "0.3.0", data: Self.zipBytes(), makeCurrent: true,
                by: admin, storage: storage, on: app.db, logger: app.logger
            )

            #expect(try await WorkerRelease.query(on: app.db)
                .filter(\.$isCurrent == true).count() == 1)
            #expect(try #require(try await WorkerRelease.current(on: app.db)).version == "0.3.0")

            // 되돌리기.
            try await WorkerReleaseService.makeCurrent(first, on: app.db)
            #expect(try #require(try await WorkerRelease.current(on: app.db)).version == "0.2.0")
            _ = second
        }
    }

    @Test("배포 중인 릴리스는 지울 수 없다")
    func cannotRemoveCurrent() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)
            let release = try await WorkerReleaseService.accept(
                version: "0.2.0", data: Self.zipBytes(), makeCurrent: true,
                by: admin, storage: storage, on: app.db, logger: app.logger
            )

            await #expect(throws: Abort.self) {
                try await WorkerReleaseService.remove(
                    release, storage: storage, on: app.db, logger: app.logger
                )
            }
        }
    }

    // MARK: - 워커가 받아가는 자리

    @Test("워커가 지금 배포 중인 것을 받아간다")
    func workerFetchesRelease() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)
            _ = try await WorkerReleaseService.accept(
                version: "0.9.0", data: Self.zipBytes(), makeCurrent: true,
                by: admin, storage: storage, on: app.db, logger: app.logger
            )
            let (_, token) = try await app.makeWorker(name: "cook")

            try await app.testing().test(
                .GET, APIPath.workerRelease, headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(WorkerReleaseDTO.self)
                #expect(dto.version == "0.9.0")
                #expect(!dto.downloadURL.isEmpty)
                // 받은 것이 올린 그것인지 워커가 대조한다.
                #expect(dto.sha256.count == 64)
            }
        }
    }

    @Test("배포 중인 것이 없으면 204")
    func noReleaseIsNoContent() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeWorker(name: "cook")
            try await app.testing().test(
                .GET, APIPath.workerRelease, headers: .bearer(token)
            ) { #expect($0.status == .noContent) }
        }
    }

    @Test("토큰 없이는 못 본다")
    func requiresWorkerToken() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, APIPath.workerRelease) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    // MARK: - 낡은 워커 가리기

    @Test("버전을 안 알리는 워커는 낡은 것으로 본다")
    func silentWorkerIsStale() async throws {
        try await withMigratedApp { app in
            let worker = Worker(name: "옛워커", tokenHash: "x", createdByID: nil)
            let row = try WorkerRow(worker: worker)
            #expect(row.isStale)
            #expect(row.workerVersion == "모름")
        }
    }

    @Test("서버와 같은 버전이면 낡지 않았다")
    func matchingWorkerIsFresh() async throws {
        try await withMigratedApp { app in
            let worker = Worker(name: "새워커", tokenHash: "x", createdByID: nil)
            worker.workerVersion = WorkerVersion.current
            let row = try WorkerRow(worker: worker)
            #expect(!row.isStale)
        }
    }

    @Test("하트비트로 알린 버전이 저장된다")
    func heartbeatStoresVersion() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeWorker(name: "cook")

            try await app.testing().test(
                .POST,
                APIPath.workerHeartbeat,
                headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        WorkerHeartbeat(
                            workerName: "cook",
                            osVersion: "macOS 26.3",
                            workerVersion: "0.1.0"
                        )
                    )
                }
            ) { #expect($0.status == .noContent) }

            let stored = try #require(
                try await Worker.query(on: app.db).filter(\.$name == "cook").first()
            )
            #expect(stored.workerVersion == "0.1.0")
        }
    }

    /// 워커를 옛 것으로 되돌리면 화면도 그렇게 보여야 한다. 한 번 받은 값을
    /// 붙들고 있으면 낡은 워커가 새 것으로 보인다.
    @Test("버전을 안 보내면 모름으로 되돌아간다")
    func silentHeartbeatClearsVersion() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeWorker(name: "cook")

            for version in [WorkerVersion.current, nil] {
                try await app.testing().test(
                    .POST,
                    APIPath.workerHeartbeat,
                    headers: .bearer(token),
                    beforeRequest: { request in
                        try request.content.encode(
                            WorkerHeartbeat(
                                workerName: "cook",
                                osVersion: "macOS 26.3",
                                workerVersion: version
                            )
                        )
                    }
                ) { #expect($0.status == .noContent) }
            }

            let stored = try #require(
                try await Worker.query(on: app.db).filter(\.$name == "cook").first()
            )
            #expect(stored.workerVersion == nil)
        }
    }
}
