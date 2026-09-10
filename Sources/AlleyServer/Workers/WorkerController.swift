import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 서명 워커가 쓰는 경로.
///
/// 워커는 인바운드 포트를 열지 않는다(ADR-0002). 서버가 워커를 부르는 것이 아니라
/// 워커가 서버를 long-poll 한다. 사내망 밖의 맥이든 누구 책상 아래의 맥이든 나가는
/// 연결만 되면 일한다.
public struct WorkerController: RouteCollection, Sendable {
    public init() {}

    /// long-poll 한 번이 서버를 붙잡고 있을 수 있는 최대 시간.
    ///
    /// 워커가 아무 숫자나 보내도 여기서 자른다. 프록시와 로드밸런서의 유휴 타임아웃보다
    /// 짧아야 응답이 도중에 끊기지 않는다.
    static let maximumPollSeconds = 60

    public func boot(routes: any RoutesBuilder) throws {
        let worker = routes
            .grouped(WorkerAuthenticator())
            .grouped(APIPath.workerRoot.pathComponents)

        worker.get("jobs", "next", use: nextJob)
        worker.patch("jobs", ":jobID", use: updateJob)
        worker.post("heartbeat", use: heartbeat)
    }

    // MARK: - 잡 가져가기

    /// 큐에서 잡 하나를 가져간다. 없으면 잠시 기다렸다가 204 를 준다.
    ///
    /// 기다리는 이유는 워커가 1초마다 다시 묻는 것을 막기 위해서다. 서명은 하루에 몇 번
    /// 있는 일이라, 폴링 주기를 짧게 두면 대부분의 요청이 빈손으로 돌아간다.
    @Sendable
    func nextJob(request: Request) async throws -> Response {
        let worker = try request.requireWorker()
        let requested = request.query[Int.self, at: "timeout"] ?? 25
        let deadline = Date().addingTimeInterval(
            TimeInterval(max(0, min(requested, Self.maximumPollSeconds)))
        )

        while true {
            if let job = try await claimJob(for: worker, on: request) {
                let response = Response(status: .ok)
                try response.content.encode(job)
                return response
            }
            guard Date() < deadline else { return Response(status: .noContent) }
            // 큐가 비어 있는 동안은 1초에 한 번만 들여다본다. 이 간격이 곧
            // 잡이 들어오고 워커가 알아채기까지의 지연이다.
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// 큐에서 잡 하나를 원자적으로 가져온다.
    ///
    /// `FOR UPDATE SKIP LOCKED` 로 한 문장에 끝낸다. 조회한 뒤 갱신하는 방식은 워커가
    /// 두 대 이상일 때 같은 잡을 둘이 집어간다. 서명은 부수효과가 있는 작업이라
    /// 중복 실행이 곧 중복 공증 제출이 된다.
    private func claimJob(for worker: Worker, on request: Request) async throws -> SigningJobDTO? {
        guard let sql = request.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "이 데이터베이스에서는 잡 큐를 쓸 수 없습니다.")
        }

        let workerID = try worker.requireID()
        let claimed = try await sql.raw(
            """
            UPDATE signing_jobs
               SET state = 'running',
                   worker_id = \(bind: workerID),
                   claimed_at = now(),
                   heartbeat_at = now(),
                   updated_at = now()
             WHERE id = (
                   SELECT id FROM signing_jobs
                    WHERE state = 'queued'
                    ORDER BY created_at
                    LIMIT 1
                      FOR UPDATE SKIP LOCKED
             )
            RETURNING id
            """
        ).first()

        guard let row = claimed else { return nil }
        let jobID = try row.decode(column: "id", as: UUID.self)

        // 지시서에 번들 ID 가 들어가므로 버전과 앱을 함께 읽는다.
        let query = SigningJob.query(on: request.db)
            .filter(\.$id == jobID)
            .with(\.$version) { $0.with(\.$app) }
        guard let job = try await query.first() else { return nil }

        // 버전이 서명을 받을 상태가 아니면 잡을 여기서 끝낸다. 큐에 남겨두면 워커가
        // 가져갔다 되돌리기를 반복하고, 그 사이 다른 잡이 밀린다.
        do {
            if job.version.state == .uploaded {
                try job.version.transition(to: .signing)
                try await job.version.save(on: request.db)
            } else if job.version.state != .signing, job.version.state != .notarizing {
                throw Abort(
                    .conflict,
                    reason: "버전이 서명을 받을 수 있는 상태가 아닙니다. 현재 상태: \(job.version.state.rawValue)"
                )
            }
        } catch let abort as any AbortError {
            request.logger.warning("서명 잡을 취소했습니다 [잡: \(jobID), 이유: \(abort.reason)]")
            job.state = .failed
            job.failureReason = abort.reason
            job.finishedAt = Date()
            try await job.save(on: request.db)
            return nil
        }

        // 지시서를 만들다 실패하면(스토리지가 죽었다든지) 잡은 이미 running 이다.
        // 그대로 두면 아무도 처리하지 않는 채로 갇힌다. 큐로 돌려놓고 오류를 알린다.
        let ticket: SigningJobDTO
        do {
            ticket = try await self.ticket(for: job, on: request)
        } catch {
            job.state = .queued
            job.$worker.id = nil
            job.claimedAt = nil
            try? await job.save(on: request.db)
            throw error
        }

        worker.currentJobID = jobID
        try await worker.save(on: request.db)
        return ticket
    }

    /// 워커가 일을 끝내는 데 필요한 것만 담은 지시서.
    ///
    /// 서명 identity 도 공증 자격증명도 여기 없다. 그것들은 워커 머신의 키체인에만
    /// 있고 서버는 애초에 모른다.
    private func ticket(for job: SigningJob, on request: Request) async throws -> SigningJobDTO {
        let versionID = try job.version.requireID()
        let appID = job.version.$app.id

        let download = try await request.artifactStorage.downloadURL(
            key: request.artifactStorage.newKey(
                ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .unsigned)
            )
        )
        let upload = try await request.artifactStorage.uploadURL(
            key: request.artifactStorage.newKey(
                ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .signed)
            )
        )

        // 번들 ID 가 아직 임시값이면 워커가 대조 대신 정책 검사를 한다 (ADR-0034).
        // 그러려면 정책을 함께 보내야 한다. 워커는 조직 설정을 모른다.
        let settings = try await request.storeSettings()
        let pending = job.version.app.bundleIDPending

        return SigningJobDTO(
            id: try job.requireID(),
            versionID: versionID,
            appBundleID: job.version.app.bundleID,
            appBundleIDPending: pending ? true : nil,
            requiredBundleIDPrefix: pending ? settings.bundleIDPrefix : nil,
            enforceBundleIDPrefix: pending ? settings.enforceBundleIDPrefix : nil,
            artifactDownloadURL: download.url,
            resultUploadURL: upload.url,
            // 올린 사람이 준 것이 있으면 실어 보낸다. 미서명 업로드에는 워커가 읽어낼
            // 기존 서명이 없어서, 이것 없이는 권한 없이 서명된다 (ADR-0020).
            entitlements: job.version.entitlements,
            // 둘 중 먼저 만료되는 쪽이 이 잡의 유효 기간이다.
            expiresAt: min(download.expiresAt, upload.expiresAt)
        )
    }

    // MARK: - 진행 보고

    @Sendable
    func updateJob(request: Request) async throws -> Response {
        let worker = try request.requireWorker()
        let job = try await findClaimedJob(for: worker, on: request)
        let update = try request.content.decode(SigningJobUpdate.self)

        job.heartbeatAt = Date()
        if let phase = update.phase { job.phase = phase }
        // 덮어쓰지 않고 쌓는다. 실패했을 때 정작 필요한 것은 그 직전 단계의 로그다
        // (ADR-0023).
        if let log = update.log { job.append(log, phase: job.phase) }

        switch update.state {
        case .running:
            try await advanceVersion(of: job, to: update.phase, on: request)
        case .succeeded:
            try await finishSuccessfully(job, update: update, on: request)
        case .failed:
            try await fail(job, reason: update.failureReason, code: update.failureCode, on: request)
        case .queued:
            throw Abort(.badRequest, reason: "워커가 잡을 다시 큐로 되돌릴 수는 없습니다.")
        }

        try await job.save(on: request.db)

        if update.state != .running {
            worker.currentJobID = nil
            try await worker.save(on: request.db)
        }
        return Response(status: .noContent)
    }

    private func findClaimedJob(for worker: Worker, on request: Request) async throws -> SigningJob {
        guard let jobID = request.parameters.get("jobID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "잡 ID 형식이 올바르지 않습니다.")
        }
        // 앱까지 함께 읽는다. 성공 보고를 처리할 때 번들 ID 를 확정해야 할 수 있고
        // (ADR-0034), 그 자리에서 관계를 다시 읽으면 eager load 가 안 된 채로 만져
        // 프로세스가 죽는다. 실제로 그렇게 죽었다.
        guard let job = try await SigningJob.query(on: request.db)
            .filter(\.$id == jobID)
            // 트레일링 클로저로 쓰면 `guard` 본문으로 파싱된다. 괄호 안에 넣는다.
            .with(\.$version, { $0.with(\.$app) })
            .first()
        else {
            throw Abort(.notFound, reason: "잡을 찾을 수 없습니다.")
        }
        // 남의 잡을 보고하면 상태가 엉킨다. 자기가 가져간 잡만 건드릴 수 있다.
        guard job.$worker.id == (try worker.requireID()) else {
            throw Abort(.forbidden, reason: "이 워커가 가져간 잡이 아닙니다.")
        }
        guard job.state == .running else {
            throw Abort(.conflict, reason: "이미 끝난 잡입니다. 현재 상태: \(job.state.rawValue)")
        }
        return job
    }

    /// 워커가 밟는 단계를 버전 상태에 반영한다.
    ///
    /// 워커의 단계가 더 잘게 나뉘어 있어서 전부 옮기지는 않는다. 공증에 들어가는
    /// 순간만 버전에도 남긴다. 공증은 Apple 이 잡고 있는 시간이라, 다른 단계와 달리
    /// 오래 걸리는 것이 정상인지 멈춘 것인지 화면에서 구분되어야 한다.
    private func advanceVersion(
        of job: SigningJob,
        to phase: SigningPhase?,
        on request: Request
    ) async throws {
        guard phase == .notarizing, job.version.state == .signing else { return }
        try job.version.transition(to: .notarizing)
        try await job.version.save(on: request.db)
    }

    private func finishSuccessfully(
        _ job: SigningJob,
        update: SigningJobUpdate,
        on request: Request
    ) async throws {
        let version = job.version
        let versionID = try version.requireID()
        let key = request.artifactStorage.newKey(
            ArtifactStorage.objectKey(
                appID: version.$app.id,
                versionID: versionID,
                kind: .signed
            )
        )

        // 워커가 "다 올렸다"고 말하는 것만 믿지 않는다. 여기서 확인하지 않으면
        // 아무것도 안 올라간 버전이 배포 준비됨으로 넘어간다.
        guard let size = try await request.artifactStorage.head(key: key), size > 0 else {
            // 워커가 아니라 서버가 판정한 실패라 갈래가 없다. 다시 내보내지 않는다.
            try await fail(
                job,
                reason: "서명 결과물이 스토리지에 올라오지 않았습니다.",
                code: nil,
                on: request
            )
            return
        }

        try await upsertSignedArtifact(
            versionID: versionID,
            key: key,
            sha256: update.resultSHA256?.lowercased(),
            fileSize: size,
            edSignature: update.resultEdSignature,
            on: request.db
        )

        if let metadata = update.bundleMetadata {
            applyBundleMetadata(metadata, to: version, logger: request.logger)

            // 번들 ID 가 임시값이었으면 워커가 읽어온 값으로 확정한다.
            //
            // 여기서 실패하면(정책 위반이나 중복) 서명은 이미 끝난 뒤다. 그래도
            // **버전을 배포 준비됨으로 넘기지 않는다.** 확정되지 않은 앱은 출시할 수
            // 없으므로 그대로 두면 아무도 받지 못하는 채로 남는다 (ADR-0034).
            if let declared = metadata.bundleIdentifier, version.app.bundleIDPending {
                do {
                    try await AppRegistration.confirmBundleID(
                        version.app,
                        readFromBundle: declared,
                        settings: try await request.storeSettings(),
                        on: request.db,
                        logger: request.logger
                    )
                } catch let abort as any AbortError {
                    try await fail(
                        job,
                        reason: """
                            서명은 끝났지만 번들 ID 를 확정하지 못했습니다: \(abort.reason)
                            읽어온 값: \(declared)
                            """,
                        code: nil,
                        on: request
                    )
                    return
                }
            }
        }

        // 공증을 건너뛴 워커도 있을 수 있어서 signing 에서 곧장 오는 경우를 함께 다룬다.
        if version.state == .signing {
            try version.transition(to: .notarizing)
        }
        try version.transition(to: .ready)
        try await version.save(on: request.db)

        job.state = .succeeded
        job.phase = nil
        job.failureReason = nil
        // 앞선 시도에서 일시적 실패로 되돌아온 잡이라면 갈래가 남아 있다. 성공했으니 지운다.
        job.failureCode = nil
        job.finishedAt = Date()
    }

    /// 워커가 번들에서 읽어온 값을 버전에 맞춘다.
    ///
    /// **번들이 진실이다.** 등록할 때 적힌 값은 사람이 짐작한 것일 수 있다. dmg 는
    /// 브라우저가 열 수 없어서 버전과 빌드 번호를 임시값으로 두고 시작하고
    /// (ADR-0033), 그것을 여기서 실제 값으로 바꾼다.
    ///
    /// **덮어쓰는 것이 맞는 자리다.** 브라우저 자동 채우기는 사람이 적은 값을 지키는데
    /// (ADR-0030), 그쪽은 아직 올리기 전이라 사람이 고칠 수 있다. 여기는 이미 서명·공증까지
    /// 끝난 뒤다. 실제로 배포되는 바이너리가 `1.2.4` 인데 목록에 `1.2.3` 으로 적혀 있으면
    /// 그게 더 나쁘다. 스토어 앱은 번들의 값으로 설치 여부를 판단하므로 어긋난 채 두면
    /// 업데이트 표시가 틀린다.
    ///
    /// 빌드 번호는 손대지 않는다. 앱 안에서 겹칠 수 없는 값이라 바꾸면 다른 버전과
    /// 충돌할 수 있고, 그 충돌을 여기서 풀 방법이 없다. 대신 다르면 로그에 남긴다.
    private func applyBundleMetadata(
        _ metadata: BundleMetadata,
        to version: Version,
        logger: Logger
    ) {
        if let short = metadata.shortVersion, short != version.shortVersion {
            logger.notice(
                """
                버전 번호를 번들이 밝힌 값으로 고칩니다: \
                \(version.shortVersion) -> \(short) (버전 \(version.id?.uuidString ?? "?"))
                """
            )
            version.shortVersion = short
        }
        if let minimum = metadata.minimumOSVersion, minimum != version.minimumOSVersion {
            version.minimumOSVersion = minimum
        }
        if let build = metadata.buildVersion, build != String(version.buildNumber) {
            // 고치지 않는다. 위 주석 참고.
            logger.notice(
                """
                번들의 빌드 번호가 등록된 값과 다릅니다: 등록 \(version.buildNumber), \
                번들 \(build). 겹침 검사 때문에 서버가 고치지 않습니다.
                """
            )
        }
    }

    /// 워커가 보고한 실패를 처리한다.
    ///
    /// 갈래(`code`)가 다시 해볼 만하다고 말하고 시도 상한이 남았으면 큐로 되돌린다.
    /// 그렇지 않으면 실패로 확정한다. 판단은 `SigningRetryPolicy` 한 곳에 있다
    /// (ADR-0023).
    ///
    /// `code` 가 nil 인 경우는 둘이다. 이 필드를 모르는 예전 워커가 보고했거나, 서버가
    /// 스스로 실패를 판정했거나(결과물이 안 올라온 경우). 둘 다 다시 내보내지 않는다.
    private func fail(
        _ job: SigningJob,
        reason: String?,
        code: SigningFailureCode?,
        on request: Request
    ) async throws {
        let reason = reason ?? "워커가 이유를 남기지 않고 실패를 보고했습니다."
        job.failureCode = code

        if SigningRetryPolicy.verdict(reported: code, attempt: job.attempt) == .requeue {
            requeue(job, reason: reason, on: request)
            return
        }

        // 실패한 버전은 다시 올리는 것으로 되살린다(failed → uploaded).
        // 이미 다른 상태로 옮겨간 버전까지 억지로 끌어내리지는 않는다.
        if job.version.state.canTransition(to: .failed) {
            try job.version.transition(to: .failed, reason: reason)
            try await job.version.save(on: request.db)
        }

        job.state = .failed
        job.failureReason = reason
        job.finishedAt = Date()
        request.logger.warning(
            "서명 실패 [버전: \(job.$version.id), 코드: \(code?.rawValue ?? "없음"), 이유: \(reason)]"
        )
    }

    /// 다시 해볼 만한 실패라 잡을 큐에 돌려놓는다.
    ///
    /// 버전 상태는 건드리지 않는다. `signing` 과 `notarizing` 은 워커가 다시 가져갈 수
    /// 있는 상태다. 여기서 `failed` 로 끌어내리면 다음 워커가 잡을 집어도 클레임에서
    /// 튕긴다. 멈춘 잡을 되돌릴 때와 같은 규칙이다 (ADR-0018).
    private func requeue(_ job: SigningJob, reason: String, on request: Request) {
        job.attempt += 1
        job.state = .queued
        job.$worker.id = nil
        job.claimedAt = nil
        job.heartbeatAt = nil
        job.phase = nil
        job.failureReason = reason
        job.append("다시 해볼 만한 실패라 큐로 되돌렸습니다. 시도 \(job.attempt) 회차로 다시 나갑니다.")
        request.logger.warning(
            "서명 잡을 큐로 되돌립니다 [버전: \(job.$version.id), 시도: \(job.attempt), 이유: \(reason)]"
        )
    }

    // MARK: - 하트비트

    /// 워커가 살아 있다고 알린다.
    ///
    /// 잡을 처리하는 동안에도 주기적으로 온다. 이 시각이 끊기면 워커가 죽은 것이고,
    /// 그 워커가 잡고 있던 잡은 사람이 손대야 한다는 뜻이다.
    @Sendable
    func heartbeat(request: Request) async throws -> Response {
        let worker = try request.requireWorker()
        let payload = try request.content.decode(WorkerHeartbeat.self)

        // 이름은 워커 쪽 설정이 진실이다. 머신을 옮기거나 이름을 바꿨을 때
        // 콘솔에서 옛 이름을 계속 보는 것보다 낫다.
        worker.name = payload.workerName
        worker.osVersion = payload.osVersion
        worker.currentJobID = payload.currentJobID
        worker.lastSeenAt = Date()
        try await worker.save(on: request.db)

        if let jobID = payload.currentJobID,
           let job = try await SigningJob.find(jobID, on: request.db),
           job.state == .running
        {
            job.heartbeatAt = Date()
            try await job.save(on: request.db)
        }
        return Response(status: .noContent)
    }

    private func upsertSignedArtifact(
        versionID: UUID,
        key: String,
        sha256: String?,
        fileSize: Int64,
        edSignature: String?,
        on database: any Database
    ) async throws {
        // 재시도하면 같은 키에 덮어쓴다. 행을 새로 만들면 유니크 제약에 걸린다.
        if let existing = try await Artifact.query(on: database)
            .filter(\.$version.$id == versionID)
            .filter(\.$kind == .signed)
            .first()
        {
            existing.storageKey = key
            existing.sha256 = sha256
            existing.fileSize = fileSize
            existing.edSignature = edSignature
            try await existing.save(on: database)
            return
        }

        let artifact = Artifact(
            versionID: versionID,
            kind: .signed,
            storageKey: key,
            sha256: sha256,
            fileSize: fileSize
        )
        artifact.edSignature = edSignature
        try await artifact.save(on: database)
    }
}

extension SigningJobDTO: Content {}
extension SigningJobUpdate: Content {}
extension WorkerHeartbeat: Content {}
