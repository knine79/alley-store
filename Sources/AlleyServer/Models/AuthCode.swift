import Crypto
import Fluent
import Foundation
import Vapor

/// 스토어 앱이 세션 토큰으로 바꿔갈 일회용 코드.
///
/// 로그인이 끝나면 앱의 커스텀 URL 스킴으로 돌려보내야 하는데, 세션 토큰을 그 URL 에
/// 직접 실으면 곤란하다. URL 은 시스템 로그, 브라우저 기록, 다른 앱의 URL 핸들러에
/// 남을 수 있다. 대신 수명이 짧은 일회용 코드를 실어 보내고, 앱이 그 코드를 POST 로
/// 교환해 세션 토큰을 받는다. 유출되더라도 이미 소진됐거나 곧 만료된다.
///
/// 저장할 때는 코드 자체가 아니라 해시를 넣는다. 데이터베이스가 통째로 새도
/// 그 값으로는 교환할 수 없다.
public final class AuthCode: Model, @unchecked Sendable {
    public static let schema = "auth_codes"

    @ID(key: .id)
    public var id: UUID?

    /// 발급한 코드의 SHA-256 해시(16진수).
    @Field(key: "code_hash")
    public var codeHash: String

    @Parent(key: "user_id")
    public var user: User

    @Field(key: "expires_at")
    public var expiresAt: Date

    /// 교환에 쓰인 시각. 한 번 쓰이면 다시 쓸 수 없다.
    @OptionalField(key: "consumed_at")
    public var consumedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(codeHash: String, userID: UUID, expiresAt: Date) {
        self.codeHash = codeHash
        self.$user.id = userID
        self.expiresAt = expiresAt
    }

    /// 앱이 코드를 받아 교환하기까지의 시간. 화면 전환 한 번이면 끝나므로 짧게 잡는다.
    public static let lifetime: TimeInterval = 2 * 60

    /// 새 코드를 만들고 (평문, 모델) 쌍을 돌려준다.
    ///
    /// 평문은 이 시점에만 존재한다. 저장되는 것은 해시뿐이다.
    public static func issue(userID: UUID, now: Date = Date()) -> (plaintext: String, model: AuthCode) {
        // URL 쿼리에 실리므로 URL 안전한 문자만 쓴다.
        let plaintext = [UUID().uuidString, UUID().uuidString]
            .joined()
            .replacingOccurrences(of: "-", with: "")
        let model = AuthCode(
            codeHash: hash(plaintext),
            userID: userID,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        return (plaintext, model)
    }

    public static func hash(_ plaintext: String) -> String {
        SHA256.hash(data: Data(plaintext.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func isUsable(at now: Date = Date()) -> Bool {
        consumedAt == nil && expiresAt > now
    }
}

public struct CreateAuthCode: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(AuthCode.schema)
            .id()
            .field("code_hash", .string, .required)
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .field("created_at", .datetime)
            // 교환은 해시로 조회한다. 유일 제약이 조회 인덱스 역할도 한다.
            .unique(on: "code_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(AuthCode.schema).delete()
    }
}
