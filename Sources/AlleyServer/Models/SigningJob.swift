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
    ///
    /// **덮어쓰지 않고 쌓는다** (ADR-0023). 원인 파악에 가장 필요한 것은 실패 메시지
    /// 자체가 아니라 그 직전 단계가 무엇을 하고 있었는가다. 붙이는 것은 `append`,
    /// 크기 상한은 `logLimit` 에 있다.
    @OptionalField(key: "log")
    public var log: String?

    @OptionalField(key: "failure_reason")
    public var failureReason: String?

    /// 실패의 갈래. 서버가 재시도 여부를 이것으로 판단한다 (ADR-0023).
    ///
    /// `phase` 와 같은 이유로 원시 문자열로 둔다. 워커가 늘릴 수 있는 값이라 데이터베이스
    /// enum 으로 묶으면 워커를 고칠 때마다 마이그레이션이 따라온다.
    @OptionalField(key: "failure_code")
    public var failureCodeName: String?

    public var failureCode: SigningFailureCode? {
        get { failureCodeName.flatMap(SigningFailureCode.init(rawValue:)) }
        set { failureCodeName = newValue?.rawValue }
    }

    /// 같은 버전에 대해 몇 번째 시도인지.
    @Field(key: "attempt")
    public var attempt: Int

    /// zip 말고 dmg 도 만들라는 표시 (ADR-0050).
    ///
    /// **서버가 정해서 잡에 싣는다.** 워커는 이 잡이 스토어 앱인지 모르고, 알 필요도
    /// 없다. 그 성질을 지키려고 "무엇인가" 가 아니라 "무엇을 해라" 로 싣는다.
    ///
    /// 잡에 두고 버전이나 앱에 두지 않는 이유는, 이것이 **이번 시도에 무엇을 만들지**
    /// 이기 때문이다. 재시도하면 그때 서버가 다시 정한다.
    @Field(key: "makes_disk_image")
    public var makesDiskImage: Bool

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

    public init(versionID: UUID, attempt: Int = 1, makesDiskImage: Bool = false) {
        self.$version.id = versionID
        self.state = .queued
        self.attempt = attempt
        self.makesDiskImage = makesDiskImage
    }
}

extension SigningJob {
    /// 이 버전을 서명 큐에 넣는다.
    ///
    /// 이미 기다리거나 돌고 있는 잡이 있으면 그것을 돌려준다. 업로드 완료 통지를 두 번
    /// 받았다고 같은 버전을 두 번 서명할 이유가 없다. 실패한 잡만 있으면 시도 횟수를
    /// 이어서 새 잡을 만든다.
    @discardableResult
    static func enqueue(
        versionID: UUID,
        makesDiskImage: Bool = false,
        on database: any Database
    ) async throws -> SigningJob {
        let existing = try await SigningJob.query(on: database)
            .filter(\.$version.$id == versionID)
            .sort(\.$attempt, .descending)
            .all()

        if let live = existing.first(where: { $0.state == .queued || $0.state == .running }) {
            // 이미 도는 잡의 지시를 바꾸지 않는다. 워커가 지시서를 이미 받아갔을 수
            // 있어서, 여기서 고쳐도 이번 시도에는 반영되지 않는다.
            return live
        }

        let job = SigningJob(
            versionID: versionID,
            attempt: (existing.first?.attempt ?? 0) + 1,
            makesDiskImage: makesDiskImage
        )
        try await job.save(on: database)
        return job
    }
}

extension SigningJob {
    /// 버전 상세에 함께 실을 것.
    struct Report {
        var log: String?
        var failureCode: SigningFailureCode?
    }

    /// 버전마다 가장 최근 잡의 로그와 실패 갈래.
    ///
    /// 버전별로 따로 조회하면 목록 화면에서 N+1 이 된다. 한 번에 읽어 접는다.
    static func latestReports(
        ofVersions versionIDs: [UUID],
        on database: any Database
    ) async throws -> [UUID: Report] {
        guard !versionIDs.isEmpty else { return [:] }

        let jobs = try await SigningJob.query(on: database)
            .filter(\.$version.$id ~~ versionIDs)
            .sort(\.$attempt, .ascending)
            .all()

        return jobs.reduce(into: [:]) { result, job in
            let log = (job.log?.isEmpty == false) ? job.log : nil
            guard log != nil || job.failureCode != nil else { return }
            // 시도 순으로 읽으므로 나중 것이 앞의 것을 덮는다.
            result[job.$version.id] = Report(log: log, failureCode: job.failureCode)
        }
    }
}

// MARK: - 로그 쌓기

extension SigningJob {
    /// 잡 하나가 남길 수 있는 로그의 상한.
    ///
    /// 한 잡이 만드는 양은 단계 여섯 개에 실패 메시지 하나다. 단계 줄은 짧지만 실패
    /// 메시지에는 `codesign` 출력과 공증 로그 전문이 붙어서 그것만 몇 KB 가 된다.
    /// 16KB 면 그 전부가 들어가고, 앱 상세 화면이 로그 하나로 뒤덮이지도 않는다.
    static let logLimit = 16 * 1024

    /// 로그 한 조각을 붙인다.
    ///
    /// 단계가 바뀔 때마다 부른다. 예전에는 열 하나를 덮어썼는데, 그러면 실패했을 때
    /// 남는 것이 실패 메시지 한 줄뿐이었다. 정작 필요한 것은 그 직전 단계가 무엇을
    /// 하다가 죽었는가다 (ADR-0023).
    func append(_ entry: String, phase: SigningPhase? = nil, at time: Date = Date()) {
        log = Self.appending(entry, to: log, phase: phase, at: time)
    }

    /// 붙이기의 실제 계산. 데이터베이스 없이 확인할 수 있게 순수 함수로 둔다.
    ///
    /// 상한을 넘으면 **앞을 버린다.** 실패 원인은 거의 언제나 끝에 있다. 잘랐다는
    /// 사실은 남겨야 한다. 그것이 없으면 앞부분이 원래 없었던 것인지 잘린 것인지
    /// 읽는 사람이 알 수 없다.
    static func appending(
        _ entry: String,
        to log: String?,
        phase: SigningPhase? = nil,
        at time: Date = Date()
    ) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return log ?? "" }

        let header = "[\(logTimeFormatter.string(from: time))\(phase.map { " \($0.displayName)" } ?? "")]"
        let block = "\(header) \(trimmed)"
        let joined = (log?.isEmpty == false) ? "\(log!)\n\(block)" : block
        return truncated(joined)
    }

    /// 상한을 넘긴 로그의 앞을 잘라낸다.
    static func truncated(_ log: String) -> String {
        guard log.count > logLimit else { return log }

        let kept = String(log.suffix(logLimit))
        // 줄 가운데에서 자르면 잘린 줄이 온전한 줄처럼 보인다. 다음 줄바꿈까지 버린다.
        let aligned = kept.firstIndex(of: "\n").map { String(kept[kept.index(after: $0)...]) } ?? kept
        let dropped = log.count - aligned.count
        return "…앞부분 \(dropped)자를 잘랐습니다. 실패 원인은 아래쪽에 있습니다.\n\(aligned)"
    }

    /// 로그 줄머리에 쓰는 시각. 서버 시계를 쓴다.
    ///
    /// 워커 시계를 쓰면 머신마다 어긋난 시각이 한 잡의 로그에 섞인다.
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
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

/// 실패 갈래를 담을 열 (ADR-0023).
///
/// 데이터베이스 enum 이 아니라 문자열이다. 갈래는 워커가 늘리는 값이고, enum 으로
/// 묶으면 코드 하나를 더할 때마다 마이그레이션이 따라온다. `phase` 와 같은 판단이다.
public struct AddSigningJobFailureCode: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(SigningJob.schema)
            .field("failure_code", .string)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(SigningJob.schema)
            .deleteField("failure_code")
            .update()
    }
}

/// dmg 를 만들라는 표시를 잡에 더한다 (ADR-0050).
///
/// 기본값은 거짓이다. 이미 큐에 있던 잡은 지금까지처럼 zip 만 만든다.
public struct AddSigningJobDiskImage: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(SigningJob.schema)
            .field("makes_disk_image", .bool, .required, .sql(.default(false)))
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(SigningJob.schema)
            .deleteField("makes_disk_image")
            .update()
    }
}

/// 아티팩트 갈래에 `dmg` 를 더한다 (ADR-0050).
public struct AddDiskImageArtifactKind: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        // `IF NOT EXISTS` 로 적는다. Fluent 의 enum 빌더는 그것을 만들지 못하는데,
        // 값이 이미 있을 때 그냥 지나가야 한다. 옛 데이터베이스와 새 데이터베이스가
        // 같은 자리에 도착하는지는 이 한 줄에 달려 있다.
        try await sql.raw("ALTER TYPE \"artifact_kind\" ADD VALUE IF NOT EXISTS 'dmg'").run()
    }

    public func revert(on database: any Database) async throws {
        // **되돌리지 않는다.** PostgreSQL 은 enum 에서 값을 빼지 못한다. 억지로 하려면
        // 타입을 새로 만들어 열을 옮겨야 하는데, 그 값을 쓰는 아티팩트 행까지 지워야
        // 하고 그러면 스토리지의 파일과 어긋난다. 쓰이지 않는 값 하나가 남는 편이 낫다.
    }
}
