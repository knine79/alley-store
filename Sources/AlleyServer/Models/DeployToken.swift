import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// CI 파이프라인이 앱 하나에 버전을 올릴 때 쓰는 토큰.
///
/// **앱 하나에 묶인다.** 사람의 권한을 그대로 빌려주면, CI 설정 파일에 새어나간 값
/// 하나로 그 사람이 올릴 수 있는 모든 앱이 열린다. 파이프라인은 자기 앱 하나만
/// 올리면 되므로 그만큼만 준다 (ADR-0015).
///
/// 워커 토큰과 같은 방식으로 다룬다. 해시만 저장하고, 발급 직후 한 번만 보여주고,
/// 폐기는 행을 남긴 채 시각만 찍는다.
public final class DeployToken: Model, @unchecked Sendable {
    public static let schema = "deploy_tokens"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "app_id")
    public var app: App

    /// 어느 파이프라인의 것인지 알아볼 이름. 예: `github-actions`
    @Field(key: "name")
    public var name: String

    @Field(key: "token_hash")
    public var tokenHash: String

    /// 토큰을 발급한 사람.
    ///
    /// 이 토큰으로 올라간 버전은 이 사람이 올린 것으로 기록된다. 파이프라인은
    /// 사람이 아니지만 그 파이프라인에 책임이 있는 사람은 있다.
    @Parent(key: "created_by")
    public var createdBy: User

    @OptionalField(key: "last_used_at")
    public var lastUsedAt: Date?

    @OptionalField(key: "revoked_at")
    public var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(appID: UUID, name: String, tokenHash: String, createdByID: UUID) {
        self.$app.id = appID
        self.name = name
        self.tokenHash = tokenHash
        self.$createdBy.id = createdByID
    }

    public var isActive: Bool {
        revokedAt == nil
    }

    public func toDTO() throws -> DeployTokenDTO {
        DeployTokenDTO(
            id: try requireID(),
            appID: $app.id,
            name: name,
            lastUsedAt: lastUsedAt,
            revokedAt: revokedAt,
            createdAt: createdAt ?? Date()
        )
    }
}

// MARK: - 토큰

extension DeployToken {
    /// 접두사가 워커 토큰과 다르다.
    ///
    /// 인증 미들웨어가 어느 쪽인지 값만 보고 알 수 있고, 사람도 설정 파일에서
    /// 무엇이 잘못 들어갔는지 알아본다.
    public static let prefix = "alleyd_"

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - 마이그레이션

public struct CreateDeployToken: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(DeployToken.schema)
            .id()
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("created_by", .uuid, .required, .references(User.schema, "id"))
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            // 인증은 해시로 곧장 조회한다. 유일 제약이 곧 인덱스가 된다.
            .unique(on: "token_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(DeployToken.schema).delete()
    }
}
