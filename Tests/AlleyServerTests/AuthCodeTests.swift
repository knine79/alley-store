import Foundation
import Testing

@testable import AlleyServer

@Suite("일회용 교환 코드")
struct AuthCodeTests {
    @Test("평문이 아니라 해시를 저장한다")
    func storesHashNotPlaintext() {
        let userID = UUID()
        let (plaintext, model) = AuthCode.issue(userID: userID)

        #expect(model.codeHash != plaintext)
        #expect(model.codeHash == AuthCode.hash(plaintext))
        // 데이터베이스가 새도 평문을 복원할 수 없어야 한다.
        #expect(!model.codeHash.contains(plaintext))
    }

    @Test("해시는 같은 입력에 같은 값을 낸다")
    func hashIsDeterministic() {
        #expect(AuthCode.hash("abc") == AuthCode.hash("abc"))
        #expect(AuthCode.hash("abc") != AuthCode.hash("abd"))
        // SHA-256 16진수는 64자다.
        #expect(AuthCode.hash("abc").count == 64)
    }

    @Test("발급할 때마다 다른 코드가 나온다")
    func codesAreUnique() {
        let userID = UUID()
        let codes = (0..<50).map { _ in AuthCode.issue(userID: userID).plaintext }
        #expect(Set(codes).count == codes.count)
    }

    @Test("코드는 URL 에 실을 수 있는 문자만 쓴다")
    func codeIsURLSafe() {
        let (plaintext, _) = AuthCode.issue(userID: UUID())
        let allowed = CharacterSet.alphanumerics
        #expect(plaintext.unicodeScalars.allSatisfy(allowed.contains))
        // 커스텀 스킴 URL 쿼리에 그대로 들어가므로 인코딩이 필요 없어야 한다.
        #expect(plaintext.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) == plaintext)
    }

    @Test("추측하기 어려울 만큼 길다")
    func codeIsLongEnough() {
        let (plaintext, _) = AuthCode.issue(userID: UUID())
        // UUID 두 개에서 하이픈을 뺀 길이.
        #expect(plaintext.count == 64)
    }

    @Test("발급 직후에는 쓸 수 있다")
    func isUsableRightAfterIssue() {
        let now = Date()
        let (_, model) = AuthCode.issue(userID: UUID(), now: now)
        #expect(model.isUsable(at: now))
    }

    @Test("수명이 지나면 쓸 수 없다")
    func expiresAfterLifetime() {
        let now = Date()
        let (_, model) = AuthCode.issue(userID: UUID(), now: now)
        #expect(!model.isUsable(at: now.addingTimeInterval(AuthCode.lifetime + 1)))
    }

    @Test("한 번 쓰이면 다시 쓸 수 없다")
    func cannotReuseConsumedCode() {
        let now = Date()
        let (_, model) = AuthCode.issue(userID: UUID(), now: now)
        model.consumedAt = now
        #expect(!model.isUsable(at: now))
    }
}
