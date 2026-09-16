import AlleyShared
import Fluent
import Foundation
import Vapor

/// 스토리지에 올라간 파일 하나에 대한 기록.
///
/// 파일 자체는 오브젝트 스토리지에 있고 데이터베이스에는 그 위치와 지문만 남는다.
/// 서버는 바이너리를 자기 디스크에 두지 않는다. 업로드도 다운로드도 만료 있는
/// presigned URL 로 클라이언트가 스토리지와 직접 주고받는다.
public final class Artifact: Model, @unchecked Sendable {
    public static let schema = "artifacts"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "version_id")
    public var version: Version

    @Enum(key: "kind")
    public var kind: ArtifactKind

    @Field(key: "storage_key")
    public var storageKey: String

    /// 소문자 16진수 SHA-256. 받는 쪽이 무결성을 확인한다.
    @OptionalField(key: "sha256")
    public var sha256: String?

    /// 스토리지가 알려준 실제 바이트 수. 클라이언트 신고값이 아니다.
    @OptionalField(key: "file_size")
    public var fileSize: Int64?

    /// Sparkle 이 요구하는 EdDSA(Ed25519) 서명.
    ///
    /// 서명 워커가 결과물에 대해 만들어 보고한다. 없으면 Sparkle 이 설치를 거부하므로
    /// appcast 경로를 쓰는 앱은 이 값이 있어야 한다. 스토어 앱으로 받는 경로는
    /// 이것과 무관하다(그쪽은 codesign 과 공증을 직접 확인한다).
    @OptionalField(key: "ed_signature")
    public var edSignature: String?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        versionID: UUID,
        kind: ArtifactKind,
        storageKey: String,
        sha256: String? = nil,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.$version.id = versionID
        self.kind = kind
        self.storageKey = storageKey
        self.sha256 = sha256
        self.fileSize = fileSize
    }
}

// MARK: - 마이그레이션

public struct CreateArtifact: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        // **값을 여기 그대로 적는다.** `ArtifactKind.allCases` 를 순회하면 이 마이그레이션이
        // 코드와 함께 움직인다. 갈래를 하나 더하는 순간 새 데이터베이스는 그 값을 갖고
        // 시작하는데, 뒤따르는 추가 마이그레이션은 이미 있는 값을 또 넣으려다 죽는다.
        // 마이그레이션은 그것을 쓸 당시의 스키마여야 하고, 그 뒤의 변화는 뒤에 오는
        // 마이그레이션이 맡는다 (`AddDiskImageArtifactKind`).
        var kind = database.enum("artifact_kind")
        for value in ["unsigned", "signed"] {
            kind = kind.case(value)
        }
        let artifactKind = try await kind.create()

        try await database.schema(Artifact.schema)
            .id()
            .field(
                "version_id", .uuid, .required,
                .references(Version.schema, "id", onDelete: .cascade)
            )
            .field("kind", artifactKind, .required)
            .field("storage_key", .string, .required)
            .field("sha256", .string)
            .field("file_size", .int64)
            .field("created_at", .datetime)
            // 한 버전에 같은 종류의 파일이 둘일 수 없다. 재업로드는 덮어쓴다.
            .unique(on: "version_id", "kind")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Artifact.schema).delete()
        try await database.enum("artifact_kind").delete()
    }
}

/// Sparkle 서명을 담을 자리.
public struct AddArtifactEdSignature: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Artifact.schema)
            .field("ed_signature", .string)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Artifact.schema)
            .deleteField("ed_signature")
            .update()
    }
}
