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
    /// 공급자에게서 신원을 확인받은 시각. 토큰을 갱신해도 바뀌지 않는다 (ADR-0069).
    ///
    /// 옵셔널인 것은 이 칸이 생기기 전에 발급된 토큰 때문이다. 그때는 `iat` 를 쓴다.
    /// 그 토큰들은 갱신된 적이 없으니 `iat` 가 곧 로그인 시각이다.
    public var authenticatedAt: IssuedAtClaim?

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case issuedAt = "iat"
        case authenticatedAt = "auth_time"
    }

    /// 갱신만으로 버틸 수 있는 최대 기간. 지나면 공급자에게 다시 확인받는다.
    ///
    /// 사람 토큰(`UserToken.lifetime`)과 같은 90일이다. 갱신에 끝이 없으면 한 번 새어
    /// 나간 토큰을 앱이 켜져 있는 한 계속 쓸 수 있다.
    public static let maximumAge: TimeInterval = 90 * 24 * 60 * 60

    public init(userID: UUID, issuedAt: Date, ttl: TimeInterval, authenticatedAt: Date? = nil) {
        let authenticatedAt = authenticatedAt ?? issuedAt
        self.subject = .init(value: userID.uuidString)
        self.issuedAt = .init(value: issuedAt)
        // 갱신한 토큰도 로그인한 지 90일을 넘겨 살지 않는다. 자르지 않으면 89일째에
        // 갱신한 토큰이 거기서 수명만큼 더 산다.
        self.expiration = .init(value: min(
            issuedAt.addingTimeInterval(ttl),
            authenticatedAt.addingTimeInterval(Self.maximumAge)
        ))
        self.authenticatedAt = .init(value: authenticatedAt)
    }

    /// 처음 로그인한 시각. 예전 토큰은 `iat`.
    public var authenticationDate: Date {
        authenticatedAt?.value ?? issuedAt.value
    }

    /// 이 토큰을 갱신해줘도 되는지.
    public func isRenewable(at now: Date) -> Bool {
        now.timeIntervalSince(authenticationDate) < Self.maximumAge
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
    /// 웹 로그인이 끝난 뒤 돌아갈 경로. 없으면 앱 목록이다.
    ///
    /// **서명된 state 안에 싣는다.** 쿠키나 쿼리로 따로 들고 다니면 콜백에서 누가 바꿔
    /// 끼웠는지 알 수 없다. 여기 들어오는 값은 이미 `safeReturnPath` 를 지났다.
    public var returnPath: String?
    /// 스토어 앱이 보낸 PKCE challenge. 콜백에서 발급하는 코드에 그대로 묶는다
    /// (ADR-0068).
    ///
    /// 이것도 **서명된 state 안에 싣는다.** 공급자에게 갔다 오는 동안 서버가 따로 들고
    /// 있을 자리가 없고, 밖에 두면 누가 바꿔 끼웠는지 알 수 없다.
    public var codeChallenge: String?
    /// 스토어 앱이 보낸 로그인별 무작위 값. 콜백 URL 에 그대로 돌려준다 (ADR-0068).
    public var appState: String?
    public var expiration: ExpirationClaim
    /// 재생 공격을 어렵게 하는 무작위 값.
    public var nonce: String

    enum CodingKeys: String, CodingKey {
        case target = "tgt"
        case returnPath = "ret"
        case codeChallenge = "cch"
        case appState = "ast"
        case expiration = "exp"
        case nonce = "nnc"
    }

    /// 로그인 왕복은 사람이 화면을 보고 버튼을 누르는 시간이면 충분하다.
    /// 길게 잡을수록 탈취된 state 를 쓸 수 있는 창이 넓어진다.
    public static let lifetime: TimeInterval = 10 * 60

    public init(
        target: Target,
        returnPath: String? = nil,
        codeChallenge: String? = nil,
        appState: String? = nil,
        now: Date = Date(),
        nonce: String = UUID().uuidString
    ) {
        self.target = target
        self.returnPath = returnPath
        self.codeChallenge = codeChallenge
        self.appState = appState
        self.expiration = .init(value: now.addingTimeInterval(Self.lifetime))
        self.nonce = nonce
    }

    public func verify(using algorithm: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }

    /// 돌아갈 경로로 받아도 되는 값인지. 안 되면 nil.
    ///
    /// **이 스토어 안의 상대 경로만 받는다.** 아무 주소나 받으면 로그인 화면이 남의
    /// 사이트로 보내주는 열린 리다이렉터가 된다. `//evil.example` 과 `/\evil.example`
    /// 은 `/` 로 시작하지만 브라우저가 다른 호스트로 읽는다.
    public static func safeReturnPath(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.hasPrefix("//"), !raw.hasPrefix("/\\"),
              !raw.contains(where: { $0.isNewline || $0 == "\\" }),
              raw.count <= 2048
        else { return nil }
        return raw
    }
}
