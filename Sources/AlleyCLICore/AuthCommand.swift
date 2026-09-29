import AlleyShared
import Foundation

#if canImport(Network)
import Network
#endif

/// 브라우저를 열어 이 기기를 계정에 연결한다 (ADR-0064).
///
/// 사람이 토큰을 보지도 만지지도 않는다. 클립보드에도 셸 히스토리에도 남지 않는다.
public enum AuthCommand {
    /// 사람이 브라우저에서 버튼을 누를 때까지 기다리는 한도.
    ///
    /// 포트를 여는 일이라 오래 열어두지 않는다. 로그인이 필요하면 그 시간도 여기
    /// 들어가므로 너무 짧아도 안 된다.
    static let waitLimit: TimeInterval = 3 * 60

    public enum Failure: Error, CustomStringConvertible {
        case noServer
        case cannotListen(String)
        case timedOut
        case mismatchedState
        case refused(String)
        case browserFailed

        public var description: String {
            switch self {
            case .noServer:
                return """
                    어느 스토어에 붙을지 알 수 없습니다. `--server https://store.example.com` \
                    으로 주거나 ALLEY_SERVER_URL 을 넣어주세요.
                    """
            case .cannotListen(let detail):
                return "기다릴 자리를 열지 못했습니다: \(detail)"
            case .timedOut:
                return "시간 안에 연결되지 않았습니다. 다시 시도해 주세요."
            case .mismatchedState:
                return "돌아온 값이 보낸 것과 다릅니다. 처음부터 다시 시도해 주세요."
            case .refused(let reason):
                return "서버가 거절했습니다: \(reason)"
            case .browserFailed:
                return "브라우저를 열지 못했습니다. 위 주소를 직접 열어주세요."
            }
        }
    }

    /// 이 기기를 부를 이름.
    ///
    /// **호스트명만 쓰지 않는다.** 같은 맥에서 두 번 연결하면 목록에서 구별되지 않아
    /// 무엇을 폐기할지 고를 수 없다 (ADR-0064). 연결할 때마다 다른 꼬리를 붙인다.
    static func deviceName(
        host: String = ProcessInfo.processInfo.hostName,
        suffix: String = String(UUID().uuidString.prefix(4)).lowercased()
    ) -> String {
        // `.local` 은 모두가 같아서 구별에 보태는 것이 없다.
        var name = host
        if name.hasSuffix(".local") { name.removeLast(6) }
        if name.isEmpty { name = "alley CLI" }
        return "\(name)-\(suffix)"
    }

    /// 연결하고 저장한다. 저장한 자리를 돌려준다.
    public static func login(
        server: URL,
        credentialsAt location: URL,
        openBrowser: (URL) throws -> Void = openInBrowser,
        report: (String) -> Void
    ) async throws -> Credentials.Entry {
        let state = UUID().uuidString + UUID().uuidString
        let device = deviceName()

        let listener = try LoopbackListener()
        defer { listener.stop() }

        var components = URLComponents(
            url: server.appendingPathComponent(APIPath.cliAuthorize.trimmingCharacters(in: ["/"])),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: CLIAuthQuery.port, value: String(listener.port)),
            URLQueryItem(name: CLIAuthQuery.state, value: state),
            URLQueryItem(name: CLIAuthQuery.device, value: device),
        ]
        let authorizeURL = components.url!

        report("브라우저에서 연결을 확인해 주세요.")
        report("  \(authorizeURL.absoluteString)")
        try openBrowser(authorizeURL)

        let handback = try await listener.waitForCallback(limit: waitLimit)
        guard handback.state == state else { throw Failure.mismatchedState }

        let issued = try await exchange(
            code: handback.code, device: device, server: server
        )

        var credentials = try Credentials.load(from: location)
        credentials[server.absoluteString] = Credentials.Entry(
            token: issued.token, name: issued.name, expiresAt: issued.expiresAt
        )
        try credentials.save(to: location)
        return Credentials.Entry(
            token: issued.token, name: issued.name, expiresAt: issued.expiresAt
        )
    }

    /// 일회용 코드를 사람 토큰으로 바꾼다.
    static func exchange(code: String, device: String, server: URL) async throws -> Issued {
        var request = URLRequest(
            url: server.appendingPathComponent(APIPath.cliTokenExchange.trimmingCharacters(in: ["/"]))
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code, "device": device])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data))?.reason
                ?? String(decoding: data, as: UTF8.self)
            throw Failure.refused(detail)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Issued.self, from: data)
    }

    struct Issued: Decodable {
        var token: String
        var name: String
        var expiresAt: Date
        var email: String
        var userName: String
    }

    private struct ServerError: Decodable {
        var reason: String
    }

    /// 브라우저를 연다. macOS 는 `open`, 리눅스는 `xdg-open`.
    public static func openInBrowser(_ url: URL) throws {
        #if os(macOS)
        let launcher = "/usr/bin/open"
        #else
        let launcher = "/usr/bin/xdg-open"
        #endif
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            throw Failure.browserFailed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// 주소에 싣는 값의 이름. 서버와 한 곳에서 맞춘다.
enum CLIAuthQuery {
    static let port = "port"
    static let state = "state"
    static let device = "device"
}
