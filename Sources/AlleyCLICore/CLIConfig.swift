import Foundation

/// CLI 가 도는 데 필요한 것.
///
/// 전부 환경변수에서 온다. CI 는 사람이 앉아 있지 않으므로 물어볼 수 없고, 설정
/// 파일을 두면 그 파일에 토큰이 남아 커밋될 위험이 있다.
public struct CLIConfig: Sendable {
    public var serverURL: URL
    public var token: String

    public enum ConfigError: Error, CustomStringConvertible {
        case missing(String, hint: String)
        case invalidServerURL(String)

        public var description: String {
            switch self {
            case .missing(let key, let hint):
                return "\(key) 가 필요합니다. \(hint)"
            case .invalidServerURL(let value):
                return "ALLEY_SERVER_URL 을 주소로 해석할 수 없습니다: \(value)"
            }
        }
    }

    public init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    public static func load(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CLIConfig {
        guard let rawURL = environment["ALLEY_SERVER_URL"], !rawURL.isEmpty else {
            throw ConfigError.missing("ALLEY_SERVER_URL", hint: "스토어 서버 주소입니다. 예: https://store.example.com")
        }
        guard let token = environment["ALLEY_TOKEN"], !token.isEmpty else {
            throw ConfigError.missing(
                "ALLEY_TOKEN",
                hint: """
                    앱 상세 화면에서 발급한 배포 토큰(alleyd_), 또는 내 설정 > 내 \
                    토큰에서 발급한 사람 토큰(alleyu_)입니다. mcp 는 사람 토큰이어야 \
                    합니다.
                    """
            )
        }
        guard let url = normalize(serverAddress: rawURL) else {
            throw ConfigError.invalidServerURL(rawURL)
        }
        return CLIConfig(serverURL: url, token: token)
    }

    /// 사람이 적은 주소를 쓸 수 있는 형태로 다듬는다.
    ///
    /// 스토어 앱과 같은 규칙이다. 스킴이 없으면 https 로 보고, 뒤에 붙은 슬래시를 뗀다.
    /// 경로를 조립할 때 이중 슬래시가 생기면 서버가 404 를 준다.
    public static func normalize(serverAddress raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }

        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            return nil
        }
        return url
    }
}
