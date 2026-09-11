import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리자가 올린 워커 번들 하나 (ADR-0042).
///
/// 워커는 자기 버전과 여기 적힌 버전을 견줘, 낮으면 받아서 자기를 갈아끼운다.
/// **관리자가 올리는 행위가 곧 승인이다.** 워커가 자기 다음 버전을 서명하는
/// 순환이 있어서, 사람이 한 번 끼어드는 자리가 반드시 필요하다.
public final class WorkerRelease: Model, @unchecked Sendable {
    public static let schema = "worker_releases"

    @ID(key: .id)
    public var id: UUID?

    /// `WorkerVersion.current` 와 같은 형식. 견줄 수 있어야 한다.
    @Field(key: "version")
    public var version: String

    /// 스토리지에 놓인 zip 의 키. 번들을 통째로 담은 zip 이다.
    @Field(key: "storage_key")
    public var storageKey: String

    @Field(key: "file_size")
    public var fileSize: Int64

    /// 받은 파일이 올린 그 파일인지 워커가 대조한다.
    @Field(key: "sha256")
    public var sha256: String

    /// 지금 배포할 것. **한 번에 하나만 true 다.**
    ///
    /// "가장 높은 버전" 이 아니라 따로 두는 이유는 되돌릴 수 있어야 하기 때문이다.
    /// 새 워커에 문제가 있으면 관리자가 옛 릴리스를 다시 현재로 만든다.
    @Field(key: "is_current")
    public var isCurrent: Bool

    @OptionalParent(key: "uploaded_by")
    public var uploadedBy: User?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        version: String,
        storageKey: String,
        fileSize: Int64,
        sha256: String,
        uploadedByID: UUID?
    ) {
        self.version = version
        self.storageKey = storageKey
        self.fileSize = fileSize
        self.sha256 = sha256
        self.isCurrent = false
        self.$uploadedBy.id = uploadedByID
    }

    /// 지금 배포 중인 릴리스. 없으면 nil.
    public static func current(on database: any Database) async throws -> WorkerRelease? {
        try await WorkerRelease.query(on: database)
            .filter(\.$isCurrent == true)
            .first()
    }

    /// 스토리지에 놓일 자리.
    public static func objectKey(releaseID: UUID) -> String {
        "workers/\(releaseID.uuidString).zip"
    }
}

struct CreateWorkerRelease: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WorkerRelease.schema)
            .id()
            .field("version", .string, .required)
            .field("storage_key", .string, .required)
            .field("file_size", .int64, .required)
            .field("sha256", .string, .required)
            .field("is_current", .bool, .required, .sql(.default(false)))
            .field("uploaded_by", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .unique(on: "version")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WorkerRelease.schema).delete()
    }
}
