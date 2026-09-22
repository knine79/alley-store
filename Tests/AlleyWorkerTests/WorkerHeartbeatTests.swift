import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

/// 하트비트가 Sparkle 공개키를 싣는지 본다 (ADR-0057).
///
/// **빠뜨려도 아무 데서도 오류가 나지 않는 값이다.** 서버는 nil 을 "키를 안 넣은
/// 워커" 로 받아들이고, 화면은 그대로 "이 워커는 서명하지 않는다" 를 그린다. 키를
/// 넣은 사람 눈에는 화면이 거짓말하는 것으로 보인다. 실제로 한 번 그렇게 나갔다.
@Suite("워커 하트비트")
struct WorkerHeartbeatTests {
    private func config(sparkleKey: String?) throws -> WorkerConfig {
        var environment = [
            "ALLEY_SERVER_URL": "https://store.example.com",
            "ALLEY_WORKER_TOKEN": "alleyw_" + String(repeating: "0", count: 64),
            "ALLEY_WORKER_NAME": "test-mac",
            "ALLEY_SIGNING_IDENTITY": "Developer ID Application: Example Inc. (TEAMID)",
            "ALLEY_NOTARY_PROFILE": "alley",
        ]
        environment["ALLEY_SPARKLE_PRIVATE_KEY"] = sparkleKey
        return try WorkerConfig.load(from: environment)
    }

    private func heartbeat(sparkleKey: String?) throws -> WorkerHeartbeat {
        WorkerLoop(config: try config(sparkleKey: sparkleKey), log: { _ in })
            .heartbeat(currentJobID: nil)
    }

    @Test("개인키를 넣으면 그 공개키를 싣는다")
    func carriesPublicKey() throws {
        let seed = Data(repeating: 7, count: 32).base64EncodedString()
        let expected = try SparkleSignature.publicKey(fromPrivateKeyBase64: seed)

        #expect(try heartbeat(sparkleKey: seed).sparklePublicKey == expected)
    }

    @Test("키가 없으면 nil 을 싣는다")
    func reportsNilWithoutKey() throws {
        #expect(try heartbeat(sparkleKey: nil).sparklePublicKey == nil)
    }

    /// 형식이 깨진 키로는 서명도 못 만든다. 화면이 보는 결과가 키 없는 워커와 같아야
    /// 한다.
    @Test("형식이 깨진 키는 nil 로 접는다")
    func foldsMalformedKeyToNil() throws {
        #expect(try heartbeat(sparkleKey: "이건 base64 가 아닙니다").sparklePublicKey == nil)
    }
}
