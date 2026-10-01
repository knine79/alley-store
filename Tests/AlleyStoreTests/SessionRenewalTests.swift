import Foundation
import Testing

@testable import AlleyStoreCore

/// 스토어 앱이 세션 토큰을 언제 새로 받는가 (ADR-0069).
@Suite("세션 토큰 갱신 시점")
struct SessionRenewalTimingTests {
    /// 서명은 보지 않으므로 아무 값이나 붙인다.
    private func token(iat: Double, exp: Double) -> String {
        let payload = Data(#"{"sub":"x","iat":\#(iat),"exp":\#(exp)}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).signature"
    }

    private let issued: Double = 1_790_000_000
    private let week: Double = 7 * 24 * 60 * 60

    @Test("수명의 절반이 지나기 전에는 갱신하지 않는다")
    func notBeforeHalfway() {
        let value = token(iat: issued, exp: issued + week)
        #expect(!SessionRenewal.isDue(value, now: Date(timeIntervalSince1970: issued + week / 2 - 1)))
    }

    @Test("수명의 절반이 지나면 갱신한다")
    func afterHalfway() {
        let value = token(iat: issued, exp: issued + week)
        #expect(SessionRenewal.isDue(value, now: Date(timeIntervalSince1970: issued + week / 2)))
        // 이미 만료된 것도 시도한다. 서버가 401 을 주고, 그때 로그아웃한다.
        #expect(SessionRenewal.isDue(value, now: Date(timeIntervalSince1970: issued + week + 1)))
    }

    @Test("패딩 없는 base64url 페이로드를 읽는다")
    func readsBase64URL() throws {
        // 길이가 4의 배수가 아닌 값과 `-`, `_` 가 섞인 값이 나오도록 소수 시각을 쓴다.
        let value = token(iat: issued + 0.123456, exp: issued + week + 0.5)
        let lifetime = try #require(SessionRenewal.lifetime(of: value))
        #expect(abs(lifetime.issuedAt.timeIntervalSince1970 - (issued + 0.123456)) < 0.001)
    }

    @Test("만료가 늘어났는지 본다")
    func detectsExtension() {
        let current = token(iat: issued, exp: issued + week)
        let longer = token(iat: issued + week / 2, exp: issued + week * 1.5)
        // 90일 끝에 닿으면 서버가 같은 시각에서 만료를 자른다.
        let capped = token(iat: issued + week / 2, exp: issued + week)

        #expect(SessionRenewal.extends(longer, beyond: current))
        #expect(!SessionRenewal.extends(capped, beyond: current))
        // 읽을 수 없으면 늘어난 것으로 본다. 갱신을 멈추는 쪽으로 틀리면 로그아웃된다.
        #expect(SessionRenewal.extends("not-a-jwt", beyond: current))
    }

    @Test("읽을 수 없는 토큰은 갱신하지 않는다", arguments: [
        "", "not-a-jwt", "a.b", "a.!!!.c", "a.e30.c",
    ])
    func ignoresUnreadable(_ value: String) {
        // "e30" 은 `{}` 다. iat 와 exp 가 없다.
        #expect(!SessionRenewal.isDue(value, now: Date()))
    }
}
