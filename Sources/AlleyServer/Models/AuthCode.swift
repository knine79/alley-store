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

    /// 스토어 앱이 로그인을 시작할 때 보낸 PKCE challenge (ADR-0068).
    ///
    /// 있으면 그 원래 값(verifier)을 가져온 쪽에만 내준다. 코드는 커스텀 스킴 URL 을
    /// 타고 가는데, 같은 스킴을 등록한 다른 앱이 그것을 받을 수 있다. 그 앱에는
    /// verifier 가 없다. 비어 있는 것은 CLI 가 받는 코드와 예전 앱이 받는 코드다.
    @OptionalField(key: "code_challenge")
    public var codeChallenge: String?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(codeHash: String, userID: UUID, expiresAt: Date, codeChallenge: String? = nil) {
        self.codeHash = codeHash
        self.$user.id = userID
        self.expiresAt = expiresAt
        self.codeChallenge = codeChallenge
    }

    /// 앱이 코드를 받아 교환하기까지의 시간. 화면 전환 한 번이면 끝나므로 짧게 잡는다.
    public static let lifetime: TimeInterval = 2 * 60

    /// 새 코드를 만들고 (평문, 모델) 쌍을 돌려준다.
    ///
    /// 평문은 이 시점에만 존재한다. 저장되는 것은 해시뿐이다.
    public static func issue(
        userID: UUID,
        codeChallenge: String? = nil,
        now: Date = Date()
    ) -> (plaintext: String, model: AuthCode) {
        // URL 쿼리에 실리므로 URL 안전한 문자만 쓴다.
        let plaintext = [UUID().uuidString, UUID().uuidString]
            .joined()
            .replacingOccurrences(of: "-", with: "")
        let model = AuthCode(
            codeHash: hash(plaintext),
            userID: userID,
            expiresAt: now.addingTimeInterval(lifetime),
            codeChallenge: codeChallenge
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

    /// 교환하러 온 쪽이 이 코드를 받아갈 자격이 있는지.
    ///
    /// challenge 가 묶여 있지 않으면 누구든 된다. 묶여 있으면 verifier 를 가져와야 하고,
    /// 그 SHA-256 이 challenge 와 같아야 한다.
    public func admits(verifier: String?) -> Bool {
        guard let codeChallenge else { return true }
        guard let verifier, PKCE.isWellFormed(verifier: verifier) else { return false }
        return PKCE.challenge(for: verifier) == codeChallenge
    }
}

/// RFC 7636 의 S256 방식만 쓴다.
///
/// `plain` 방식(verifier 를 그대로 challenge 로 보내는 것)은 받지 않는다. 그러면
/// 주소를 본 쪽이 verifier 도 아는 셈이라 지키는 것이 없다.
public enum PKCE {
    /// verifier 의 SHA-256 을 base64url(패딩 없음)로 적는다.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SHA-256 을 base64url 로 적으면 언제나 43자다. 그 밖의 값은 받지 않는다.
    public static func isWellFormed(challenge: String) -> Bool {
        challenge.count == 43 && challenge.unicodeScalars.allSatisfy(isUnreserved)
    }

    /// RFC 7636 이 정한 길이(43~128자)와 문자.
    public static func isWellFormed(verifier: String) -> Bool {
        (43...128).contains(verifier.count) && isUnreservedOnly(verifier)
    }

    /// RFC 3986 의 unreserved 문자(영숫자와 `-._~`)만 들어 있는지. URL 에 그대로 실을 수 있다.
    public static func isUnreservedOnly(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy(isUnreserved)
    }

    private static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~": return true
        default: return false
        }
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

/// 코드에 PKCE challenge 를 묶을 자리 (ADR-0068).
///
/// `CreateAuthCode` 를 고치지 않고 새로 만든다. 이미 마이그레이션을 돌린 데이터베이스는
/// 그 파일을 다시 읽지 않는다.
public struct AddAuthCodeChallenge: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(AuthCode.schema)
            .field("code_challenge", .string)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(AuthCode.schema)
            .deleteField("code_challenge")
            .update()
    }
}
