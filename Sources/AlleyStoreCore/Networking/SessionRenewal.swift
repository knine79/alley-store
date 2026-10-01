import Foundation

/// 세션 토큰을 언제 새로 받을지 (ADR-0069).
///
/// 토큰은 서버가 서명한 JWT 다. 앱은 서명을 확인하지 않고 `iat` 와 `exp` 만 읽는다.
/// 이 값으로 정하는 것은 "갱신을 물어볼지" 뿐이고, 토큰이 유효한지는 서버가 정한다.
enum SessionRenewal {
    /// 수명의 절반이 지났으면 갱신한다.
    ///
    /// **만료 직전까지 기다리지 않는다.** 앱은 켜질 때와 목록을 갱신할 때(30분마다)만
    /// 확인하고, 노트북을 덮어두면 그 사이가 며칠이 된다. 절반이면 수명이 7일일 때
    /// 3일 반 동안 앱을 한 번도 켜지 않아야 놓친다.
    ///
    /// 읽을 수 없는 토큰이면 갱신하지 않는다. 그런 토큰은 서버가 401 로 답하고, 그때
    /// 로그아웃하면 된다. 여기서 갱신을 시도하면 같은 실패를 30분마다 되풀이한다.
    static func isDue(_ token: String, now: Date = Date()) -> Bool {
        guard let (issuedAt, expiresAt) = lifetime(of: token), expiresAt > issuedAt else {
            return false
        }
        let halfway = issuedAt.addingTimeInterval(expiresAt.timeIntervalSince(issuedAt) / 2)
        return now >= halfway
    }

    /// 토큰의 발급 시각과 만료 시각.
    static func lifetime(of token: String) -> (issuedAt: Date, expiresAt: Date)? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])) else { return nil }

        struct Claims: Decodable {
            let iat: Double
            let exp: Double
        }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { return nil }
        return (Date(timeIntervalSince1970: claims.iat), Date(timeIntervalSince1970: claims.exp))
    }

    /// JWT 는 패딩 없는 base64url 을 쓴다. `Data(base64Encoded:)` 는 둘 다 모른다.
    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
