import Foundation
import JWT
import Vapor

/// 로그인한 사용자에게 발급하는 세션 토큰.
///
/// **역할(role)을 담지 않는다.** 토큰에 역할을 넣으면 관리자에서 강등된 사용자가
/// 토큰 만료까지 관리자로 남는다. 세션 수명이 며칠 단위라 무시할 수 없는 구멍이다.
/// 그래서 토큰은 "누구인가"만 증명하고, "무엇을 할 수 있는가"는 요청마다
/// 데이터베이스에서 읽는다. 조회 한 번을 더 하는 대신 권한 변경이 즉시 반영된다.
public struct SessionToken: JWTPayload, Sendable {
    /// 사용자 ID.
    public var subject: SubjectClaim
    public var expiration: ExpirationClaim
    public var issuedAt: IssuedAtClaim

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case issuedAt = "iat"
    }

    public init(userID: UUID, issuedAt: Date, ttl: TimeInterval) {
        self.subject = .init(value: userID.uuidString)
        self.issuedAt = .init(value: issuedAt)
        self.expiration = .init(value: issuedAt.addingTimeInterval(ttl))
    }

    public func verify(using algorithm: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }

    /// 토큰이 가리키는 사용자 ID. 형식이 깨졌으면 nil.
    public var userID: UUID? {
        UUID(uuidString: subject.value)
    }
}

/// OAuth `state` 파라미터에 실어 보내는 토큰.
///
/// `state` 는 두 가지 일을 한다. 하나는 CSRF 방어이고, 다른 하나는 인증이 끝난 뒤
/// 어디로 돌려보낼지 기억하는 것이다. 서버에 세션 저장소를 두지 않으려고
/// 서명된 짧은 수명 토큰에 담아 보낸다. 서명이 있으므로 위조할 수 없고,
/// 수명이 짧아 재사용 창이 좁다.
public struct OAuthStateToken: JWTPayload, Sendable {
    /// 인증 후 돌아갈 곳.
    public enum Target: String, Codable, Sendable {
        /// 브라우저에서 시작한 로그인. 웹 콘솔로 돌아간다.
        case web
        /// 스토어 앱에서 시작한 로그인. 커스텀 URL 스킴으로 돌아간다.
        case app
    }

    public var target: Target
    public var expiration: ExpirationClaim
    /// 재생 공격을 어렵게 하는 무작위 값.
    public var nonce: String

    enum CodingKeys: String, CodingKey {
        case target = "tgt"
        case expiration = "exp"
        case nonce = "nnc"
    }

    /// 로그인 왕복은 사람이 화면을 보고 버튼을 누르는 시간이면 충분하다.
    /// 길게 잡을수록 탈취된 state 를 쓸 수 있는 창이 넓어진다.
    public static let lifetime: TimeInterval = 10 * 60

    public init(target: Target, now: Date = Date(), nonce: String = UUID().uuidString) {
        self.target = target
        self.expiration = .init(value: now.addingTimeInterval(Self.lifetime))
        self.nonce = nonce
    }

    public func verify(using algorithm: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }
}
