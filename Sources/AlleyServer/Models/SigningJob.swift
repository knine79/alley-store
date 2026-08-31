import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 서명·공증을 기다리는 작업 한 건.
///
/// 큐가 서버에 있는 이유는 워커가 죽어도 일이 사라지지 않아야 하기 때문이다
/// (ADR-0002). 워커는 인바운드 포트를 열지 않고 이 표를 long-poll 로 가져간다.
///
/// 버전과 1:1 이 아니다. 실패하고 다시 올리면 새 잡이 생긴다. 몇 번째 시도였고
/// 그때 로그가 무엇이었는지가 남아야 반복되는 실패를 알아볼 수 있다.
public final class SigningJob: Model, @unchecked Sendable {
    public static let schema = "signing_jobs"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "version_id")
    public var version: Version

    @Enum(key: "state")
    public var state: SigningJobState

    /// 이 잡을 가져간 워커. 큐에서 기다리는 동안에는 비어 있다.
    @OptionalParent(key: "worker_id")
    public var worker: Worker?

    /// 워커가 지금 밟고 있는 단계. 화면에 그대로 보여준다.
    ///
    /// 원시 문자열로 둔다. Fluent 는 모르는 Codable 타입을 JSON 으로 감싸서 넣는데,
    /// 그러면 열에 따옴표 붙은 값이 들어가 SQL 로 들여다볼 때 걸리적거린다.
    /// 단계는 워커가 늘릴 수 있는 값이라 데이터베이스 enum 으로 묶지도 않았다.
    @OptionalField(key: "phase")
    public var phaseName: String?

    public var phase: SigningPhase? {
        get { phaseName.flatMap(SigningPhase.init(rawValue:)) }
        set { phaseName = newValue?.rawValue }
    }

    /// 워커가 보내온 로그. 실패했을 때 이것만 보고 원인을 찾을 수 있어야 한다.
    @OptionalField(key: "log")
    public var log: String?

    @OptionalField(key: "failure_reason")
    public var failureReason: String?

    /// 같은 버전에 대해 몇 번째 시도인지.
    @Field(key: "attempt")
    public var attempt: Int

    @OptionalField(key: "claimed_at")
    public var claimedAt: Date?

    /// 마지막으로 워커가 살아 있다고 알린 시각. 멈춘 잡을 되돌릴 때 기준이 된다.
    @OptionalField(key: "heartbeat_at")
    public var heartbeatAt: Date?

    @OptionalField(key: "finished_at")
    public var finishedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(versionID: UUID, attempt: Int = 1) {
        self.$version.id = versionID
        self.state = .queued
        self.attempt = attempt
    }
}

extension SigningJob {
    /// 이 버전을 서명 큐에 넣는다.
    ///
    /// 이미 기다리거나 돌고 있는 잡이 있으면 그것을 돌려준다. 업로드 완료 통지를 두 번
    /// 받았다고 같은 버전을 두 번 서명할 이유가 없다. 실패한 잡만 있으면 시도 횟수를
    /// 이어서 새 잡을 만든다.
    @discardableResult
    static func enqueue(versionID: UUID, on database: any Database) async throws -> SigningJob {
        let existing = try await SigningJob.query(on: database)
            .filter(\.$version.$id == versionID)
            .sort(\.$attempt, .descending)
            .all()

        if let live = existing.first(where: { $0.state == .queued || $0.state == .running }) {
            return live
        }

        let job = SigningJob(versionID: versionID, attempt: (existing.first?.attempt ?? 0) + 1)
        try await job.save(on: database)
        return job
    }
}

extension SigningJob {
    /// 버전마다 가장 최근 잡의 로그.
    ///
    /// 버전별로 따로 조회하면 목록 화면에서 N+1 이 된다. 한 번에 읽어 접는다.
    static func latestLogs(
        ofVersions versionIDs: [UUID],
        on database: any Database
    ) async throws -> [UUID: String] {
        guard !versionIDs.isEmpty else { return [:] }

        let jobs = try await SigningJob.query(on: database)
            .filter(\.$version.$id ~~ versionIDs)
            .sort(\.$attempt, .ascending)
            .all()

        return jobs.reduce(into: [:]) { result, job in
            guard let log = job.log, !log.isEmpty else { return }
            // 시도 순으로 읽으므로 나중 것이 앞의 것을 덮는다.
            result[job.$version.id] = log
        }
    }
}

// MARK: - 마이그레이션

public struct CreateSigningJobEnum: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        var state = database.enum("signing_job_state")
        for value in SigningJobState.allCases {
            state = state.case(value.rawValue)
        }
        _ = try await state.create()
    }

    public func revert(on database: any Database) async throws {
        try await database.enum("signing_job_state").delete()
    }
}

public struct CreateSigningJob: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        let state = try await database.enum("signing_job_state").read()

        try await database.schema(SigningJob.schema)
            .id()
            .field(
                "version_id", .uuid, .required,
                .references(Version.schema, "id", onDelete: .cascade)
            )
            .field("state", state, .required)
            .field("worker_id", .uuid, .references(Worker.schema, "id", onDelete: .setNull))
            .field("phase", .string)
            .field("log", .string)
            .field("failure_reason", .string)
            .field("attempt", .int, .required)
            .field("claimed_at", .datetime)
            .field("heartbeat_at", .datetime)
            .field("finished_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // 워커는 "기다리는 잡 중 가장 오래된 것"만 조회한다. 그 질의 하나를 위한 인덱스다.
        try await (database as? any SQLDatabase)?.raw(
            "CREATE INDEX IF NOT EXISTS signing_jobs_queue_idx ON signing_jobs (state, created_at)"
        ).run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(SigningJob.schema).delete()
    }
}
