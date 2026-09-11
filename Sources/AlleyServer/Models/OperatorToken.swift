import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// 운영 파이프라인이 스토어를 갱신할 때 쓰는 토큰 (ADR-0043).
///
/// 운영 레포의 CI 가 새 워커 릴리스를 올립니다. 관리자 API 는 세션 쿠키로만
/// 인증하는데, 파이프라인은 브라우저가 아니라 로그인할 수 없습니다.
///
/// **워커 토큰을 쓸 수는 없습니다.** 워커가 자기 다음 버전을 올릴 수 있게 되면
/// [ADR-0042](../../docs/adr/0042-worker-self-update.md) 가 사람을 끼워둔 자리가
/// 사라집니다. 배포 토큰도 아닙니다 - 그것은 앱 하나에 묶입니다(ADR-0015).
///
/// 다른 토큰들과 같은 방식으로 다룹니다. 해시만 저장하고, 발급 직후 한 번만
/// 보여주고, 폐기는 행을 남긴 채 시각만 찍습니다.
public final class OperatorToken: Model, @unchecked Sendable {
    public static let schema = "operator_tokens"

    @ID(key: .id)
    public var id: UUID?

    /// 어느 파이프라인의 것인지 알아볼 이름. 예: `alley-ops`
    @Field(key: "name")
    public var name: String

    @Field(key: "token_hash")
    public var tokenHash: String

    /// 토큰을 발급한 관리자. 파이프라인은 사람이 아니지만 책임자는 있다.
    @Parent(key: "created_by")
    public var createdBy: User

    @OptionalField(key: "last_used_at")
    public var lastUsedAt: Date?

    @OptionalField(key: "revoked_at")
    public var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(name: String, tokenHash: String, createdByID: UUID) {
        self.name = name
        self.tokenHash = tokenHash
        self.$createdBy.id = createdByID
    }

    public var isActive: Bool { revokedAt == nil }

    /// 값만 보고 어느 토큰인지 알 수 있게 접두어를 붙인다.
    ///
    /// 설정 파일에 배포 토큰을 잘못 넣었을 때, 인증이 실패하는 것보다 "이건 배포
    /// 토큰입니다" 를 말해줄 수 있는 편이 낫다.
    public static let prefix = "alleyo_"

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

public struct CreateOperatorToken: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(OperatorToken.schema)
            .id()
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("created_by", .uuid, .required, .references(User.schema, "id"))
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(OperatorToken.schema).delete()
    }
}
