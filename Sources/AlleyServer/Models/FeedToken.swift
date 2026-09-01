import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// Sparkle 이 appcast 를 받아갈 때 쓰는 앱별 토큰.
///
/// **읽기 전용이다.** 이 토큰으로 할 수 있는 것은 그 앱의 출시본 목록을 보고 받는
/// 것뿐이다. 배포 토큰(ADR-0015)과 표를 나눈 이유가 그것이다. 한 표에 두고 종류로
/// 구분하면, 미들웨어가 한 번 잘못 판단할 때 읽기 토큰이 쓰기 문을 연다.
///
/// Sparkle 은 우리가 만든 클라이언트가 아니라서 `Authorization` 헤더를 붙일 수 없다.
/// 피드 주소의 질의 항목으로 받는다. 그 대가는 ADR-0017 에 적었다.
public final class FeedToken: Model, @unchecked Sendable {
    public static let schema = "feed_tokens"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "app_id")
    public var app: App

    @Field(key: "name")
    public var name: String

    @Field(key: "token_hash")
    public var tokenHash: String

    @OptionalParent(key: "created_by")
    public var createdBy: User?

    @OptionalField(key: "last_used_at")
    public var lastUsedAt: Date?

    @OptionalField(key: "revoked_at")
    public var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(appID: UUID, name: String, tokenHash: String, createdByID: UUID?) {
        self.$app.id = appID
        self.name = name
        self.tokenHash = tokenHash
        self.$createdBy.id = createdByID
    }

    public var isActive: Bool {
        revokedAt == nil
    }

    public func toDTO() throws -> FeedTokenDTO {
        FeedTokenDTO(
            id: try requireID(),
            appID: $app.id,
            name: name,
            lastUsedAt: lastUsedAt,
            revokedAt: revokedAt,
            createdAt: createdAt ?? Date()
        )
    }
}

extension FeedToken {
    /// 배포 토큰(`alleyd_`)과 다른 접두사를 쓴다. 값만 보고 무엇인지 알 수 있어야 한다.
    public static let prefix = "alleyf_"

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

public struct CreateFeedToken: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(FeedToken.schema)
            .id()
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("created_by", .uuid, .references(User.schema, "id"))
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(FeedToken.schema).delete()
    }
}
