import Foundation

/// 서명 워커 설정.
///
/// 워커는 서명 인증서를 다루는 유일한 구성요소다. 개인키는 이 머신의 키체인에만
/// 존재하고 서버로 올라가지 않는다. 그래서 서명 identity와 공증 자격증명은
/// 서버 설정이 아니라 여기, 워커 로컬 환경에서만 읽는다.
public struct WorkerConfig: Sendable {
    /// 잡을 받아올 서버 주소.
    public var serverURL: URL
    /// 워커 인증 토큰. 관리자가 웹 콘솔에서 발급한다.
    public var token: String
    /// 웹 콘솔에 표시할 워커 이름.
    public var name: String
    /// `security find-identity` 로 조회되는 서명 identity 이름.
    /// 예: `Developer ID Application: Example Inc. (TEAMID)`
    public var signingIdentity: String
    /// `notarytool store-credentials` 로 키체인에 저장해둔 프로필 이름.
    /// 자격증명 자체를 환경변수로 들고 있지 않으려고 프로필 방식을 쓴다.
    public var notaryProfile: String
    /// 잡 처리용 임시 디렉터리.
    public var workDirectory: URL
    /// long-poll 한 번의 대기 시간(초).
    public var pollTimeout: Int
    /// Sparkle 이 요구하는 EdDSA 서명에 쓸 개인키(base64, 32바이트 시드).
    ///
    /// 없으면 서명을 만들지 않는다. appcast 경로를 쓰지 않는 조직에는 필요 없는
    /// 값이라 필수로 두지 않는다. 서명 인증서와 같은 이유로 이 머신에만 둔다
    /// (ADR-0017).
    public var sparklePrivateKey: String?

    public enum LoadError: Error, CustomStringConvertible {
        case missing(key: String)
        case invalid(key: String, reason: String)

        public var description: String {
            switch self {
            case .missing(let key):
                return "필수 환경변수 \(key) 가 설정되지 않았습니다."
            case .invalid(let key, let reason):
                return "환경변수 \(key) 값이 올바르지 않습니다: \(reason)"
            }
        }
    }

    public static func load(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> WorkerConfig {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty else {
                throw LoadError.missing(key: key)
            }
            return value
        }

        let rawServerURL = try required("ALLEY_SERVER_URL")
        guard let serverURL = URL(string: rawServerURL), serverURL.scheme != nil else {
            throw LoadError.invalid(key: "ALLEY_SERVER_URL", reason: "올바른 URL이어야 합니다.")
        }

        let workDirectory: URL
        if let raw = environment["ALLEY_WORK_DIR"], !raw.isEmpty {
            workDirectory = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("alley-worker", isDirectory: true)
        }

        let pollTimeout: Int
        if let raw = environment["ALLEY_POLL_TIMEOUT"], !raw.isEmpty {
            guard let parsed = Int(raw), parsed > 0 else {
                throw LoadError.invalid(key: "ALLEY_POLL_TIMEOUT", reason: "양의 정수여야 합니다.")
            }
            pollTimeout = parsed
        } else {
            pollTimeout = 30
        }

        return WorkerConfig(
            serverURL: serverURL,
            token: try required("ALLEY_WORKER_TOKEN"),
            name: environment["ALLEY_WORKER_NAME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? ProcessInfo.processInfo.hostName,
            signingIdentity: try required("ALLEY_SIGNING_IDENTITY"),
            notaryProfile: try required("ALLEY_NOTARY_PROFILE"),
            workDirectory: workDirectory,
            pollTimeout: pollTimeout,
            sparklePrivateKey: environment["ALLEY_SPARKLE_PRIVATE_KEY"]
                .flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
