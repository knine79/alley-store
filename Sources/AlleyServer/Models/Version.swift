import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱의 버전 하나. 업로드부터 조직 내부 출시까지의 수명을 갖는다.
///
/// 상태 전이 규칙은 `VersionState` 가 갖고 있고, 여기서는 그 규칙을 어기는 저장을
/// 막는 역할만 한다. 규칙을 서버와 클라이언트가 공유해야 해서 `AlleyShared` 에 둔다.
public final class Version: Model, @unchecked Sendable {
    public static let schema = "versions"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "app_id")
    public var app: App

    @Field(key: "short_version")
    public var shortVersion: String

    @Field(key: "build_number")
    public var buildNumber: Int

    @OptionalField(key: "release_notes")
    public var releaseNotes: String?

    @OptionalField(key: "minimum_os_version")
    public var minimumOSVersion: String?

    @Enum(key: "state")
    public var state: VersionState

    /// 이 버전을 어떤 파이프라인으로 처리할지. 만들 때 정하고 바꾸지 않는다.
    @Enum(key: "upload_kind")
    public var uploadKind: UploadKind

    /// 서명할 때 붙일 entitlements plist 의 XML 원문. 안 올렸으면 nil (ADR-0020).
    ///
    /// 형식은 받을 때 확인한다. 여기 들어온 것은 최상위가 사전인 plist 다.
    @OptionalField(key: "entitlements")
    public var entitlements: String?

    @Parent(key: "created_by")
    public var createdBy: User

    /// `failed` 로 넘어간 이유. 사람이 읽고 고칠 수 있는 문장이어야 한다.
    @OptionalField(key: "failure_reason")
    public var failureReason: String?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @OptionalField(key: "released_at")
    public var releasedAt: Date?

    @Children(for: \.$version)
    public var artifacts: [Artifact]

    public init() {}

    public init(
        id: UUID? = nil,
        appID: UUID,
        shortVersion: String,
        buildNumber: Int,
        releaseNotes: String? = nil,
        minimumOSVersion: String? = nil,
        uploadKind: UploadKind,
        entitlements: String? = nil,
        createdByID: UUID,
        state: VersionState = .draft
    ) {
        self.id = id
        self.$app.id = appID
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.releaseNotes = releaseNotes
        self.minimumOSVersion = minimumOSVersion
        self.uploadKind = uploadKind
        self.entitlements = entitlements
        self.$createdBy.id = createdByID
        self.state = state
    }
}

extension Version {
    /// 허용된 전이인지 확인하고 상태를 옮긴다.
    ///
    /// 저장은 하지 않는다. 같은 트랜잭션에서 다른 변경과 함께 저장하는 경우가 많아서
    /// 저장 시점은 호출자가 정하게 둔다.
    public func transition(to next: VersionState, reason: String? = nil) throws {
        guard state.canTransition(to: next) else {
            throw Abort(
                .conflict,
                reason: "버전 상태를 \(state.rawValue) 에서 \(next.rawValue) 로 바꿀 수 없습니다."
            )
        }
        state = next
        switch next {
        case .released:
            releasedAt = Date()
            failureReason = nil
        case .failed:
            failureReason = reason
        default:
            failureReason = nil
        }
    }

    public func toDTO() throws -> VersionDTO {
        // 배포 대상은 서명본이다. 미서명 업로드는 서명본이 생기기 전까지 크기·해시가 없다.
        let artifact = bestArtifact
        return VersionDTO(
            id: try requireID(),
            appID: $app.id,
            shortVersion: shortVersion,
            buildNumber: buildNumber,
            releaseNotes: releaseNotes,
            minimumOSVersion: minimumOSVersion,
            state: state,
            fileSize: artifact?.fileSize,
            sha256: artifact?.sha256,
            createdAt: createdAt ?? Date(),
            releasedAt: releasedAt
        )
    }

    /// 사용자에게 내려줄 아티팩트. 서명본이 있으면 그것을, 없으면 올린 그대로.
    ///
    /// `artifacts` 를 미리 `with(\.$artifacts)` 로 읽어두지 않았으면 nil 을 준다.
    public var bestArtifact: Artifact? {
        guard let loaded = $artifacts.value else { return nil }
        return loaded.first { $0.kind == .signed } ?? loaded.first { $0.kind == .unsigned }
    }
}

// MARK: - 마이그레이션

public struct CreateVersionEnums: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        var state = database.enum("version_state")
        for value in VersionState.allCases {
            state = state.case(value.rawValue)
        }
        _ = try await state.create()

        var kind = database.enum("upload_kind")
        for value in UploadKind.allCases {
            kind = kind.case(value.rawValue)
        }
        _ = try await kind.create()
    }

    public func revert(on database: any Database) async throws {
        try await database.enum("upload_kind").delete()
        try await database.enum("version_state").delete()
    }
}

public struct CreateVersion: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        let state = try await database.enum("version_state").read()
        let uploadKind = try await database.enum("upload_kind").read()

        try await database.schema(Version.schema)
            .id()
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field("short_version", .string, .required)
            .field("build_number", .int, .required)
            .field("release_notes", .string)
            .field("minimum_os_version", .string)
            .field("state", state, .required)
            .field("upload_kind", uploadKind, .required)
            .field("created_by", .uuid, .required, .references(User.schema, "id"))
            .field("failure_reason", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("released_at", .datetime)
            // 빌드 번호가 겹치면 macOS 가 어느 쪽이 최신인지 판단할 수 없다.
            .unique(on: "app_id", "build_number")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Version.schema).delete()
    }
}

/// 업로더가 함께 올린 entitlements plist 를 담을 열 (ADR-0020).
///
/// `CreateVersion` 을 고치지 않고 열을 덧붙인다. 이미 마이그레이션을 돌린 데이터베이스는
/// 그 파일을 다시 실행하지 않으므로, 기존 파일을 고치면 새로 세우는 곳에서만 열이 생긴다.
public struct AddVersionEntitlements: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Version.schema)
            .field("entitlements", .string)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Version.schema)
            .deleteField("entitlements")
            .update()
    }
}
