import AlleyShared
import Fluent
import Foundation
import Vapor

/// 운영 CI 가 올린 `alley` 바이너리 하나 (ADR-0065).
///
/// **번들이 아니라 맨 실행 파일이다.** 스토어 앱은 `.app` 이라 조직 이름과 아이콘을
/// 입혀야 하지만(ADR-0046) CLI 는 고칠 것이 없다. 조직마다 다른 값은 사람이
/// `alley auth login --server` 로 주고, 그 뒤로는 저장된 것을 쓴다 (ADR-0064).
/// 그래서 올라온 바이트를 그대로 내준다.
///
/// `WorkerRelease` 와 같은 모양이다 (ADR-0042). 같은 문제를 풀기 때문이다.
public final class CLIRelease: Model, @unchecked Sendable {
    public static let schema = "cli_releases"

    @ID(key: .id)
    public var id: UUID?

    /// `AlleyVersion.current` 와 같은 형식.
    @Field(key: "version")
    public var version: String

    /// 스토리지에 놓인 바이너리의 키.
    @Field(key: "storage_key")
    public var storageKey: String

    @Field(key: "file_size")
    public var fileSize: Int64

    /// 받은 파일이 올린 그 파일인지 대조할 값.
    @Field(key: "sha256")
    public var sha256: String

    /// 지금 내줄 것. **한 번에 하나만 true 다.**
    ///
    /// "가장 높은 버전" 이 아니라 따로 두는 이유는 되돌릴 수 있어야 하기 때문이다.
    /// 새 CLI 에 문제가 있으면 관리자가 옛 릴리스를 다시 현재로 만든다.
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

    /// 지금 내주는 릴리스. 없으면 nil.
    public static func current(on database: any Database) async throws -> CLIRelease? {
        try await CLIRelease.query(on: database)
            .filter(\.$isCurrent == true)
            .first()
    }

    /// 스토리지에 놓일 자리.
    ///
    /// 확장자를 붙이지 않는다. 받는 사람이 `alley` 라는 이름 그대로 PATH 에 두는
    /// 것이 자연스럽고, 내줄 때 이름은 헤더로 정한다.
    public static func objectKey(releaseID: UUID) -> String {
        "cli/\(releaseID.uuidString)"
    }
}

struct CreateCLIRelease: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(CLIRelease.schema)
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
        try await database.schema(CLIRelease.schema).delete()
    }
}
