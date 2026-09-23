import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// 사람이 쥐는 토큰 (ADR-0060).
///
/// 에이전트가 이 사람 대신 움직일 때 쓴다. 브라우저 없이 붙을 수 있어야 하고, 앱
/// 하나가 아니라 그 사람이 속한 앱들을 다뤄야 해서 배포 토큰으로는 되지 않는다.
///
/// **권한을 따로 좁히지 않는다.** 그 사람이 화면에서 할 수 있는 것은 이 토큰으로도
/// 된다. 그래서 인증에 성공하면 그 사람으로 로그인시킨다. 좁히지 않은 대가는
/// ADR-0060 의 나쁜 점에 적어뒀다.
///
/// 다른 토큰들과 같은 방식이다. 해시만 저장하고, 발급 직후 한 번만 보여주고, 폐기는
/// 행을 남긴 채 시각만 찍는다 (ADR-0013).
public final class UserToken: Model, @unchecked Sendable {
    public static let schema = "user_tokens"

    /// 만료까지의 기간.
    ///
    /// **끝이 있어야 한다.** 이 값은 그 사람이 할 수 있는 모든 것을 할 수 있고
    /// 에이전트 손에 있다. 도난당해도 언젠가는 죽어야 한다. 분기에 한 번 갱신하는
    /// 정도라 귀찮음도 감당할 만하다.
    public static let lifetime: TimeInterval = 90 * 24 * 60 * 60

    /// 만료 전에 미리 알리는 시점.
    public static let noticeWindow: TimeInterval = 7 * 24 * 60 * 60

    @ID(key: .id)
    public var id: UUID?

    /// 어디에 넣어둔 토큰인지 알아볼 이름. 예: `노트북 Claude Code`
    @Field(key: "name")
    public var name: String

    @Field(key: "token_hash")
    public var tokenHash: String

    /// 이 토큰이 대신하는 사람.
    @Parent(key: "user_id")
    public var user: User

    @Field(key: "expires_at")
    public var expiresAt: Date

    @OptionalField(key: "last_used_at")
    public var lastUsedAt: Date?

    @OptionalField(key: "revoked_at")
    public var revokedAt: Date?

    /// 만료가 가깝다고 마지막으로 알린 시각.
    ///
    /// 쓸고 지나갈 때마다 같은 말을 보내면 일주일 동안 매일 온다. 한 번만 보낸다.
    @OptionalField(key: "expiry_noticed_at")
    public var expiryNoticedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(name: String, tokenHash: String, userID: UUID, expiresAt: Date) {
        self.name = name
        self.tokenHash = tokenHash
        self.$user.id = userID
        self.expiresAt = expiresAt
    }

    /// 지금 쓸 수 있는 토큰인가.
    public func isUsable(at moment: Date = Date()) -> Bool {
        revokedAt == nil && expiresAt > moment
    }

    /// 값만 보고 어느 토큰인지 알 수 있게 접두어를 붙인다.
    ///
    /// 워커(`alleyw_`)·배포(`alleyd_`)·운영(`alleyo_`)·피드(`alleyf_`) 다음이다.
    /// 설정 파일에 엉뚱한 것을 넣었을 때 "이건 배포 토큰입니다" 를 말해줄 수 있다.
    public static let prefix = UserTokenPrefix.person

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

public struct CreateUserToken: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(UserToken.schema)
            .id()
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            // 사람이 끊기면 그 토큰도 끊긴다 (ADR-0061). 행까지 지우는 것은 사람을
            // 지울 때뿐인데 사람은 지우지 않으므로, 여기서는 참조만 건다.
            .field("user_id", .uuid, .required, .references(User.schema, "id"))
            .field("expires_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .field("expiry_noticed_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(UserToken.schema).delete()
    }
}
