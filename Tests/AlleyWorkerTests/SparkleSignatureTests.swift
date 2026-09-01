import Crypto
import Foundation
import Testing

@testable import AlleyWorkerCore

@Suite("Sparkle 서명")
struct SparkleSigningTests {
    /// 테스트용 Ed25519 키 한 쌍.
    private func makeKey() -> (seedBase64: String, publicKey: Curve25519.Signing.PublicKey) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey)
    }

    private func makeFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-sparkle-\(UUID().uuidString).zip")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("서명이 그 키로 검증된다")
    func signatureVerifies() throws {
        let key = makeKey()
        let file = try makeFile("배포할 앱")
        defer { try? FileManager.default.removeItem(at: file) }

        let signature = try SparkleSignature.sign(file: file, privateKeyBase64: key.seedBase64)
        let raw = try #require(Data(base64Encoded: signature))

        // Sparkle 은 내려받은 파일에 대해 같은 검증을 한다. 여기서 맞지 않으면
        // 사용자 쪽에서 업데이트가 조용히 거부된다.
        let contents = try Data(contentsOf: file)
        #expect(key.publicKey.isValidSignature(raw, for: contents))
    }

    @Test("파일이 다르면 서명도 다르다")
    func signatureBindsToContent() throws {
        let key = makeKey()
        let first = try makeFile("빌드 1")
        let second = try makeFile("빌드 2")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let one = try SparkleSignature.sign(file: first, privateKeyBase64: key.seedBase64)
        let two = try SparkleSignature.sign(file: second, privateKeyBase64: key.seedBase64)
        #expect(one != two)
    }

    @Test("64바이트 키에서도 앞 32바이트를 쓴다")
    func acceptsSeedAndPublicKeyPair() throws {
        let key = Curve25519.Signing.PrivateKey()
        // 시드와 공개키를 붙여 내놓는 도구가 있다.
        let combined = (key.rawRepresentation + key.publicKey.rawRepresentation)
            .base64EncodedString()

        let file = try makeFile("앱")
        defer { try? FileManager.default.removeItem(at: file) }

        let signature = try SparkleSignature.sign(file: file, privateKeyBase64: combined)
        let raw = try #require(Data(base64Encoded: signature))
        let contents = try Data(contentsOf: file)
        #expect(key.publicKey.isValidSignature(raw, for: contents))
    }

    @Test("키를 읽지 못하면 무엇을 넣어야 하는지 알려준다", arguments: [
        "", "쓰레기", "dG9vLXNob3J0",
    ])
    func rejectsBadKey(_ raw: String) {
        #expect(throws: SparkleSignature.SignatureError.self) {
            try SparkleSignature.privateKey(fromBase64: raw)
        }
    }

    @Test("앱에 넣을 공개키를 뽑는다")
    func derivesPublicKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation.base64EncodedString()

        // 앱의 SUPublicEDKey 에 넣는 값이다.
        let derived = try SparkleSignature.publicKey(fromPrivateKeyBase64: seed)
        #expect(derived == key.publicKey.rawRepresentation.base64EncodedString())
    }
}
