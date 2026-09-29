import Foundation

/// 브라우저로 받아둔 토큰을 담는 파일 (ADR-0064).
///
/// `~/.config/alley/credentials` 에 서버 주소별로 적는다. `gh`, `aws`, `docker` 가
/// 모두 같은 자리에 같은 방식으로 둔다.
///
/// **레포 안에 두지 않는다.** `CLIConfig` 가 환경변수만 읽던 이유가 "설정 파일을
/// 두면 커밋될 위험이 있다" 였는데, 그 걱정은 작업 디렉터리에 두는 파일 이야기다.
/// 홈 아래 0600 파일은 다르다.
///
/// 형식은 INI 에 가깝다. 사람이 열어보고 고칠 수 있어야 한다. 붙지 않을 때 가장 먼저
/// 하는 일이 이 파일을 열어보는 것이다.
///
/// ```
/// [https://store.example.com]
/// token = alleyu_...
/// name = Knineui-MacBookPro-a3f9
/// expires = 2026-12-27T09:00:00Z
/// ```
public struct Credentials: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var token: String
        public var name: String?
        public var expiresAt: Date?

        public init(token: String, name: String? = nil, expiresAt: Date? = nil) {
            self.token = token
            self.name = name
            self.expiresAt = expiresAt
        }
    }

    /// 서버 주소 → 그 서버에서 받은 것.
    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public subscript(server: String) -> Entry? {
        get { entries[Self.key(for: server)] }
        set { entries[Self.key(for: server)] = newValue }
    }

    /// 저장된 서버가 하나뿐이면 그것.
    ///
    /// 환경변수 없이 `alley mcp` 를 부를 수 있게 해준다. 붙은 서버가 하나인 사람이
    /// 대부분이고, 그 사람에게 주소를 다시 적게 할 이유가 없다.
    public var onlyServer: (server: String, entry: Entry)? {
        guard entries.count == 1, let pair = entries.first else { return nil }
        return (pair.key, pair.value)
    }

    /// 주소를 키로 쓸 수 있게 다듬는다. 뒤 슬래시만 떼면 충분하다.
    static func key(for server: String) -> String {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: - 파일

    /// 기본 자리. `XDG_CONFIG_HOME` 을 따른다.
    public static func defaultLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return base
            .appendingPathComponent("alley", isDirectory: true)
            .appendingPathComponent("credentials")
    }

    public static func load(from url: URL) throws -> Credentials {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Credentials()
        }
        return parse(text)
    }

    /// **0600 으로 쓴다.** 같은 기계의 다른 사용자가 읽지 못하게 한다. 먼저 만들고
    /// 권한을 주면 그 사이에 열려 있는 순간이 생기므로 만들 때 함께 준다.
    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = Data(rendered().utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw Failure.cannotWrite(url)
            }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotWrite(URL)

        public var description: String {
            switch self {
            case .cannotWrite(let url):
                return "자격증명을 저장하지 못했습니다: \(url.path)"
            }
        }
    }

    // MARK: - 읽고 쓰기

    static func parse(_ text: String) -> Credentials {
        var entries: [String: Entry] = [:]
        var server: String?
        var token: String?
        var name: String?
        var expires: Date?

        func flush() {
            if let server, let token {
                entries[key(for: server)] = Entry(token: token, name: name, expiresAt: expires)
            }
            token = nil
            name = nil
            expires = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                server = String(line.dropFirst().dropLast())
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let field = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch field {
            case "token": token = value
            case "name": name = value
            case "expires": expires = ISO8601DateFormatter().date(from: value)
            default: break
            }
        }
        flush()
        return Credentials(entries: entries)
    }

    func rendered() -> String {
        var lines = [
            "# alley 가 만든 파일입니다. 토큰이 들어 있으니 옮기거나 공유하지 마세요.",
            "# 지우면 `alley auth login` 으로 다시 받으면 됩니다.",
            "",
        ]
        let formatter = ISO8601DateFormatter()
        for server in entries.keys.sorted() {
            guard let entry = entries[server] else { continue }
            lines.append("[\(server)]")
            lines.append("token = \(entry.token)")
            if let name = entry.name { lines.append("name = \(name)") }
            if let expiresAt = entry.expiresAt {
                lines.append("expires = \(formatter.string(from: expiresAt))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
