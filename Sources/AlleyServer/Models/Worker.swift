import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// 등록된 서명 워커 한 대.
///
/// **토큰 원문은 저장하지 않는다.** SHA-256 해시만 남긴다. 데이터베이스 백업이
/// 유출돼도 그것만으로 워커를 사칭할 수 없어야 하기 때문이다. 그래서 토큰은 발급
/// 직후 한 번만 화면에 보이고, 잃어버리면 새로 발급받아야 한다.
///
/// 해시에 소금을 치지 않는 이유는 토큰이 사람이 정한 비밀번호가 아니라 서버가 만든
/// 256비트 난수라서다. 사전 공격의 대상이 아니고, 해시로 곧장 조회할 수 있어야
/// 요청마다 전수 비교를 하지 않는다. 자세한 배경은 ADR-0013 에 있다.
public final class Worker: Model, @unchecked Sendable {
    public static let schema = "workers"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "name")
    public var name: String

    /// 토큰의 SHA-256 16진수 소문자.
    @Field(key: "token_hash")
    public var tokenHash: String

    /// 마지막으로 서버에 말을 건 시각. 잡 폴링과 하트비트 양쪽이 갱신한다.
    @OptionalField(key: "last_seen_at")
    public var lastSeenAt: Date?

    @OptionalField(key: "os_version")
    public var osVersion: String?

    /// 지금 잡고 있는 잡. 워커가 죽었는지 판단할 때 쓴다.
    /// 워커가 마지막으로 알린 자기 버전 (ADR-0042). 이 필드를 모르는 옛 워커는 nil.
    @OptionalField(key: "worker_version")
    public var workerVersion: String?

    @OptionalField(key: "current_job_id")
    public var currentJobID: UUID?

    /// 폐기 시각. 행을 지우지 않는 이유는 잡 이력이 이 워커를 가리키기 때문이다.
    @OptionalField(key: "revoked_at")
    public var revokedAt: Date?

    /// 조용하다고 마지막으로 알린 시각.
    ///
    /// 같은 워커에 대해 5분마다 같은 말을 반복하면 아무도 안 읽게 된다.
    @OptionalField(key: "alerted_at")
    public var alertedAt: Date?

    @OptionalParent(key: "created_by")
    public var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(name: String, tokenHash: String, createdByID: UUID?) {
        self.name = name
        self.tokenHash = tokenHash
        self.$createdBy.id = createdByID
    }

    public var isActive: Bool {
        revokedAt == nil
    }

    public func toDTO() throws -> WorkerDTO {
        WorkerDTO(
            id: try requireID(),
            name: name,
            lastSeenAt: lastSeenAt,
            osVersion: osVersion,
            workerVersion: workerVersion,
            currentJobID: currentJobID,
            revokedAt: revokedAt,
            createdAt: createdAt ?? Date()
        )
    }
}

// MARK: - 토큰

extension Worker {
    /// 새 워커 토큰을 만든다.
    ///
    /// 접두사를 붙여두면 로그나 설정 파일에서 이 문자열이 무엇인지 알아볼 수 있고,
    /// 시크릿 스캐너가 잡아내기도 쉽다.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        // base64 의 +/= 는 환경변수와 URL 에서 번거롭다. 16진수로 둔다.
        return "alleyw_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - 마이그레이션

public struct CreateWorker: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Worker.schema)
            .id()
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("last_seen_at", .datetime)
            .field("os_version", .string)
            .field("current_job_id", .uuid)
            .field("revoked_at", .datetime)
            .field("created_by", .uuid, .references(User.schema, "id"))
            .field("created_at", .datetime)
            // 인증은 해시로 곧장 조회한다. 유일 제약이 곧 인덱스가 된다.
            .unique(on: "token_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Worker.schema).delete()
    }
}

/// 조용해진 워커를 알렸는지 기록할 자리.
///
/// `CreateWorker` 를 고치지 않고 새로 만든다. 이미 마이그레이션을 돌린 데이터베이스는
/// 그 파일을 다시 읽지 않으므로, 고쳐봐야 새로 만드는 사람에게만 반영된다.
public struct AddWorkerAlertedAt: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Worker.schema)
            .field("alerted_at", .datetime)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Worker.schema)
            .deleteField("alerted_at")
            .update()
    }
}

/// 워커가 알린 자기 버전을 담을 열 (ADR-0042).
///
/// 이 값이 없어서, dmg 를 모르는 워커가 dmg 를 zip 으로 풀다 "번들 구조 문제" 라는
/// 엉뚱한 진단을 내놓는 것을 한참 못 알아봤다.
struct AddWorkerVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Worker.schema)
            .field("worker_version", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Worker.schema)
            .deleteField("worker_version")
            .update()
    }
}
