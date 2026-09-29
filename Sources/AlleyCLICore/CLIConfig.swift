import Foundation

/// CLI 가 도는 데 필요한 것.
///
/// **환경변수가 먼저, 그다음이 저장해둔 것이다.** CI 는 사람이 앉아 있지 않아
/// 브라우저를 열 수 없으므로 배포 토큰을 환경변수로 준다. 사람이 쓰는 자리에서는
/// `alley auth login` 이 받아둔 것을 쓴다 (ADR-0064).
///
/// 저장 파일은 홈 아래 0600 이다 (`Credentials`). 레포 안에 두면 커밋될 위험이
/// 있다는 것이 환경변수만 읽던 이유였는데, 그 걱정은 작업 디렉터리 이야기다.
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
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialsAt location: URL? = nil
    ) throws -> CLIConfig {
        let file = location ?? Credentials.defaultLocation(environment: environment)
        let saved = (try? Credentials.load(from: file)) ?? Credentials()

        // 주소는 환경변수가 먼저다. 없고 저장된 서버가 하나뿐이면 그것으로 본다.
        // 붙은 서버가 하나인 사람에게 주소를 다시 적게 할 이유가 없다.
        let rawURL = environment["ALLEY_SERVER_URL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? saved.onlyServer?.server
        guard let rawURL else {
            throw ConfigError.missing(
                "ALLEY_SERVER_URL",
                hint: """
                    스토어 서버 주소입니다. 예: https://store.example.com \
                    `alley auth login --server <주소>` 로 붙여두면 다음부터 없어도 됩니다.
                    """
            )
        }
        guard let url = normalize(serverAddress: rawURL) else {
            throw ConfigError.invalidServerURL(rawURL)
        }

        if let token = environment["ALLEY_TOKEN"], !token.isEmpty {
            return CLIConfig(serverURL: url, token: token)
        }
        if let entry = saved[url.absoluteString] {
            return CLIConfig(serverURL: url, token: entry.token)
        }
        throw ConfigError.missing(
            "ALLEY_TOKEN",
            hint: """
                `alley auth login` 으로 브라우저에서 연결하거나, CI 라면 앱 상세 \
                화면에서 발급한 배포 토큰(alleyd_)을 환경변수로 주세요. mcp 는 사람 \
                토큰(alleyu_)이어야 합니다.
                """
        )
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
