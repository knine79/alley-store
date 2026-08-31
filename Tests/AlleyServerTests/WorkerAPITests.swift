import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("워커 인증")
struct WorkerAuthTests {
    private let nextJobPath = "\(APIPath.nextJob)?timeout=0"

    @Test("토큰이 없으면 거절한다")
    func requiresToken() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, nextJobPath) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("모르는 토큰을 거절한다")
    func rejectsUnknownToken() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(
                .GET, nextJobPath, headers: .bearer("alleyw_deadbeef")
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("폐기된 워커의 토큰은 통하지 않는다")
    func rejectsRevokedWorker() async throws {
        try await withMigratedApp { app in
            let (worker, token) = try await app.makeWorker()
            worker.revokedAt = Date()
            try await worker.save(on: app.db)

            // 워커 머신을 회수했는데 토큰이 계속 통하면 폐기가 폐기가 아니다.
            try await app.testing().test(
                .GET, nextJobPath, headers: .bearer(token)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("사용자 세션으로는 워커 경로에 들어갈 수 없다")
    func userSessionIsNotAWorker() async throws {
        try await withMigratedApp { app in
            let (_, userToken) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 사용자 토큰과 워커 토큰은 다른 신원이다. 관리자라도 잡을 가져갈 수 없다.
            try await app.testing().test(
                .GET, nextJobPath, headers: .bearer(userToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("말을 걸면 마지막 접속 시각이 남는다")
    func touchesLastSeen() async throws {
        try await withMigratedApp { app in
            let (worker, token) = try await app.makeWorker()
            #expect(worker.lastSeenAt == nil)

            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) { _ in }

            let stored = try #require(try await Worker.find(try worker.requireID(), on: app.db))
            #expect(stored.lastSeenAt != nil)
        }
    }
}

@Suite("서명 잡 큐")
struct SigningJobQueueTests {
    private let nextJobPath = "\(APIPath.nextJob)?timeout=0"

    /// 서명을 기다리는 버전 하나를 만든다.
    private func seedPendingVersion(
        on app: Application,
        state: VersionState = .uploaded
    ) async throws -> (version: Version, job: SigningJob) {
        let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: state, by: owner
        )
        let job = try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)
        return (version, job)
    }

    @Test("큐가 비면 204 를 준다")
    func emptyQueueGivesNoContent() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, token) = try await app.makeWorker()

            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) {
                #expect($0.status == .noContent)
            }
        }
    }

    @Test("잡을 가져가면 버전이 서명 중으로 넘어간다")
    func claimingStartsSigning() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, token) = try await app.makeWorker()
            let (version, job) = try await seedPendingVersion(on: app)

            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) { response in
                #expect(response.status == .ok)
                let ticket = try response.content.decode(SigningJobDTO.self)
                #expect(ticket.id == (try job.requireID()))
                #expect(ticket.appBundleID == "com.example.tool")
                // 워커는 이 URL 만으로 일을 끝낼 수 있어야 한다.
                #expect(ticket.artifactDownloadURL.contains("unsigned.zip"))
                #expect(ticket.resultUploadURL.contains("signed.zip"))
            }

            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .signing)

            let storedJob = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(storedJob.state == .running)
            #expect(storedJob.claimedAt != nil)
        }
    }

    @Test("가져간 잡은 다른 워커에게 다시 나가지 않는다")
    func claimedJobIsNotHandedOutTwice() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, first) = try await app.makeWorker(name: "첫째")
            let (_, second) = try await app.makeWorker(name: "둘째")
            _ = try await seedPendingVersion(on: app)

            try await app.testing().test(.GET, nextJobPath, headers: .bearer(first)) {
                #expect($0.status == .ok)
            }
            // 같은 잡을 둘이 집어가면 공증을 두 번 제출하게 된다.
            try await app.testing().test(.GET, nextJobPath, headers: .bearer(second)) {
                #expect($0.status == .noContent)
            }
        }
    }

    @Test("서명받을 상태가 아닌 버전의 잡은 취소한다")
    func cancelsJobForUnexpectedVersionState() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (_, token) = try await app.makeWorker()
            // 이미 출시된 버전에 잡이 남아 있는 상황. 큐에 두면 워커가 가져갔다
            // 되돌리기를 반복하면서 뒤의 잡을 막는다.
            let (_, job) = try await seedPendingVersion(on: app, state: .released)

            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) {
                #expect($0.status == .noContent)
            }

            let stored = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(stored.state == .failed)
        }
    }

    @Test("업로드를 마치면 서명 잡이 큐에 들어간다")
    func completingUploadEnqueues() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()

            var ticket: UploadTicket?
            try await app.testing().test(
                .POST, APIPath.versions(ofApp: appID), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateVersionRequest(shortVersion: "1.0.0", buildNumber: 1)
                    )
                }
            ) { response in
                #expect(response.status == .created)
                ticket = try response.content.decode(UploadTicket.self)
            }
            let versionID = try #require(ticket?.version.id)

            // 브라우저나 CLI 가 스토리지로 직접 올린 상태를 만든다.
            storage.place(
                key: ArtifactStorage.objectKey(
                    appID: appID, versionID: versionID, kind: .unsigned
                ),
                size: 2048
            )

            try await app.testing().test(
                .POST, APIPath.completeUpload(versionID: versionID), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(CompleteUploadRequest(sha256: "abc"))
                }
            ) { response in
                #expect(response.status == .ok)
                let version = try response.content.decode(VersionDTO.self)
                // 미서명 업로드는 여기서 멈추고 워커가 이어받는다.
                #expect(version.state == .uploaded)
            }

            let job = try #require(
                try await SigningJob.query(on: app.db)
                    .filter(\.$version.$id == versionID)
                    .first()
            )
            #expect(job.state == .queued)
        }
    }

    @Test("완성본을 올리면 서명 잡을 만들지 않는다")
    func signedUploadSkipsQueue() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()

            var ticket: UploadTicket?
            try await app.testing().test(
                .POST, APIPath.versions(ofApp: appID), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateVersionRequest(
                            shortVersion: "1.0.0", buildNumber: 1, uploadKind: .signed
                        )
                    )
                }
            ) { ticket = try $0.content.decode(UploadTicket.self) }
            let versionID = try #require(ticket?.version.id)

            storage.place(
                key: ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .signed),
                size: 2048
            )
            try await app.testing().test(
                .POST, APIPath.completeUpload(versionID: versionID), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(CompleteUploadRequest())
                }
            ) { response in
                let version = try response.content.decode(VersionDTO.self)
                // 이미 서명·공증을 마쳤으니 워커가 할 일이 없다.
                #expect(version.state == .ready)
            }

            let count = try await SigningJob.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test("같은 버전을 두 번 큐에 넣지 않는다")
    func enqueueIsIdempotent() async throws {
        try await withMigratedApp { app in
            let (version, first) = try await seedPendingVersion(on: app)
            let second = try await SigningJob.enqueue(
                versionID: try version.requireID(), on: app.db
            )

            // 업로드 완료 통지를 두 번 받았다고 두 번 서명할 이유가 없다.
            #expect(try first.requireID() == (try second.requireID()))
            let count = try await SigningJob.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    @Test("실패한 뒤 다시 넣으면 시도 횟수가 올라간다")
    func retryIncrementsAttempt() async throws {
        try await withMigratedApp { app in
            let (version, first) = try await seedPendingVersion(on: app)
            first.state = .failed
            try await first.save(on: app.db)

            let retry = try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)
            // 몇 번째 시도였는지가 남아야 반복되는 실패를 알아볼 수 있다.
            #expect(retry.attempt == 2)
        }
    }
}

@Suite("서명 진행 보고")
struct SigningJobReportTests {
    private let nextJobPath = "\(APIPath.nextJob)?timeout=0"

    /// 워커가 잡을 하나 가져간 상태를 만든다.
    private func claimedJob(
        on app: Application,
        storage: FakeArtifactStorage
    ) async throws -> (token: String, version: Version, job: SigningJob) {
        let (_, token) = try await app.makeWorker()
        let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: .uploaded, by: owner
        )
        try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

        var claimed: SigningJobDTO?
        try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) { response in
            claimed = try response.content.decode(SigningJobDTO.self)
        }
        let ticket = try #require(claimed)
        let job = try #require(try await SigningJob.find(ticket.id, on: app.db))
        _ = storage
        return (token, version, job)
    }

    private func updatePath(_ job: SigningJob) throws -> String {
        "\(APIPath.workerRoot)/jobs/\(try job.requireID().uuidString)"
    }

    @Test("공증에 들어가면 버전 상태에도 남는다")
    func notarizingIsReflected() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app, storage: storage)

            try await app.testing().test(
                .PATCH, try updatePath(job), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        SigningJobUpdate(state: .running, phase: .notarizing, log: "제출함")
                    )
                }
            ) { #expect($0.status == .noContent) }

            // 공증은 Apple 이 잡고 있는 시간이라, 오래 걸리는 것이 정상인지
            // 멈춘 것인지 화면에서 구분되어야 한다.
            let stored = try #require(try await Version.find(try version.requireID(), on: app.db))
            #expect(stored.state == .notarizing)
        }
    }

    @Test("성공을 보고하면 서명본이 붙고 배포 준비됨이 된다")
    func successAttachesSignedArtifact() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app, storage: storage)
            let versionID = try version.requireID()
            let key = ArtifactStorage.objectKey(
                appID: version.$app.id, versionID: versionID, kind: .signed
            )
            storage.place(key: key, size: 4096)

            try await app.testing().test(
                .PATCH, try updatePath(job), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        SigningJobUpdate(state: .succeeded, resultSHA256: "ABCDEF", resultSize: 4096)
                    )
                }
            ) { #expect($0.status == .noContent) }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .ready)

            let artifact = try #require(
                try await Artifact.query(on: app.db)
                    .filter(\.$version.$id == versionID)
                    .filter(\.$kind == .signed)
                    .first()
            )
            // 크기는 스토리지가 말하는 것을 믿는다. 해시는 워커만 계산할 수 있다.
            #expect(artifact.fileSize == 4096)
            #expect(artifact.sha256 == "abcdef")
        }
    }

    @Test("결과물이 안 올라왔으면 성공으로 치지 않는다")
    func missingResultIsFailure() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app, storage: storage)

            // 워커가 "다 올렸다"고만 말하고 실제로는 아무것도 안 올린 경우다.
            try await app.testing().test(
                .PATCH, try updatePath(job), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(SigningJobUpdate(state: .succeeded))
                }
            ) { #expect($0.status == .noContent) }

            let storedVersion = try #require(
                try await Version.find(try version.requireID(), on: app.db)
            )
            #expect(storedVersion.state == .failed)

            let storedJob = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(storedJob.state == .failed)
            #expect(storedJob.failureReason?.contains("스토리지") == true)
        }
    }

    @Test("실패를 보고하면 이유가 버전에 남는다")
    func failureIsRecorded() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (token, version, job) = try await claimedJob(on: app, storage: storage)

            try await app.testing().test(
                .PATCH, try updatePath(job), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        SigningJobUpdate(
                            state: .failed,
                            log: "codesign: 오류",
                            failureReason: "서명 identity 를 찾지 못했습니다."
                        )
                    )
                }
            ) { #expect($0.status == .noContent) }

            // 올린 사람이 로그를 보고 스스로 고칠 수 있어야 한다.
            let stored = try #require(try await Version.find(try version.requireID(), on: app.db))
            #expect(stored.state == .failed)
            #expect(stored.failureReason == "서명 identity 를 찾지 못했습니다.")

            let storedJob = try #require(try await SigningJob.find(try job.requireID(), on: app.db))
            #expect(storedJob.log == "codesign: 오류")
        }
    }

    @Test("남의 잡은 보고할 수 없다")
    func cannotReportOthersJob() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (_, _, job) = try await claimedJob(on: app, storage: storage)
            let (_, intruder) = try await app.makeWorker(name: "다른 워커")

            try await app.testing().test(
                .PATCH, try updatePath(job), headers: .bearer(intruder),
                beforeRequest: { request in
                    try request.content.encode(SigningJobUpdate(state: .failed))
                }
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("끝난 잡은 다시 보고할 수 없다")
    func cannotReportFinishedJob() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (token, _, job) = try await claimedJob(on: app, storage: storage)
            job.state = .succeeded
            try await job.save(on: app.db)

            try await app.testing().test(
                .PATCH, try updatePath(job), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(SigningJobUpdate(state: .failed))
                }
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test("하트비트가 워커 정보를 갱신한다")
    func heartbeatUpdatesWorker() async throws {
        try await withMigratedApp { app in
            let (worker, token) = try await app.makeWorker(name: "예전 이름")

            try await app.testing().test(
                .POST, APIPath.workerHeartbeat, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        WorkerHeartbeat(workerName: "새 이름", osVersion: "26.0")
                    )
                }
            ) { #expect($0.status == .noContent) }

            // 이름은 워커 쪽 설정이 진실이다. 콘솔에서 옛 이름을 계속 보는 것보다 낫다.
            let stored = try #require(try await Worker.find(try worker.requireID(), on: app.db))
            #expect(stored.name == "새 이름")
            #expect(stored.osVersion == "26.0")
            #expect(stored.lastSeenAt != nil)
        }
    }
}
