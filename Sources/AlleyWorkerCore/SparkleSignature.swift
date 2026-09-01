import Crypto
import Foundation

/// Sparkle 이 appcast 에서 요구하는 EdDSA 서명.
///
/// Sparkle 2 는 내려받은 파일이 우리가 만든 것인지 Ed25519 서명으로 확인한다.
/// 서명이 없거나 맞지 않으면 설치를 거부한다. 코드 서명·공증과는 별개의 검사다.
///
/// **Sparkle 이 배포하는 `sign_update` 도구를 쓰지 않는다.** 그 도구가 하는 일은
/// 파일에 Ed25519 서명을 하고 base64 로 내놓는 것뿐이라, 워커 머신에 도구를 하나 더
/// 깔게 하는 대신 여기서 직접 한다. 개인키는 서명 인증서와 같은 이유로 이 머신에만
/// 둔다 (ADR-0017).
public enum SparkleSignature {
    public enum SignatureError: Error, CustomStringConvertible {
        case malformedKey

        public var description: String {
            """
            ALLEY_SPARKLE_PRIVATE_KEY 를 읽지 못했습니다. \
            32바이트 시드를 base64 로 넣으세요. Sparkle 의 generate_keys 가 만든 키를 \
            쓰거나, `openssl rand -base64 32` 로 새로 만들 수 있습니다.
            """
        }
    }

    /// 파일에 서명하고 base64 로 돌려준다.
    ///
    /// 파일을 통째로 메모리에 올린다. Ed25519 는 스트리밍 서명이 아니라 전체 바이트에
    /// 대해 계산해야 한다. 수백 MB 짜리 앱에서 이 순간 메모리를 그만큼 쓴다.
    public static func sign(file: URL, privateKeyBase64: String) throws -> String {
        let key = try privateKey(fromBase64: privateKeyBase64)
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return try key.signature(for: data).base64EncodedString()
    }

    /// base64 시드에서 키를 만든다.
    ///
    /// Sparkle 의 `generate_keys` 는 개인키를 32바이트 시드의 base64 로 내놓는다.
    /// 64바이트(시드 + 공개키)를 주는 도구도 있어서 앞 32바이트만 쓴다.
    static func privateKey(fromBase64 raw: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: trimmed), decoded.count >= 32 else {
            throw SignatureError.malformedKey
        }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: decoded.prefix(32))
        } catch {
            throw SignatureError.malformedKey
        }
    }

    /// 개인키에 대응하는 공개키. 앱의 `SUPublicEDKey` 에 넣는 값이다.
    public static func publicKey(fromPrivateKeyBase64 raw: String) throws -> String {
        try privateKey(fromBase64: raw).publicKey.rawRepresentation.base64EncodedString()
    }
}
