import Foundation
import Testing

@testable import AlleyCLICore

/// 브라우저로 받아둔 것을 담는 파일 (ADR-0064).
@Suite("자격증명 파일")
struct CredentialsTests {
    private func withTemporaryFile(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alley-creds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("credentials"))
    }

    @Test("쓰고 다시 읽으면 같다")
    func aRoundTripKeepsEverything() throws {
        try withTemporaryFile { url in
            var credentials = Credentials()
            let expires = Date(timeIntervalSince1970: 1_800_000_000)
            credentials["https://store.example.com"] = Credentials.Entry(
                token: "alleyu_abc", name: "mac-a3f9", expiresAt: expires
            )
            try credentials.save(to: url)

            let read = try Credentials.load(from: url)
            let entry = try #require(read["https://store.example.com"])
            #expect(entry.token == "alleyu_abc")
            #expect(entry.name == "mac-a3f9")
            #expect(entry.expiresAt == expires)
        }
    }

    /// 같은 기계의 다른 사용자가 읽으면 안 된다.
    @Test("파일은 0600 으로 만든다")
    func theFileIsPrivate() throws {
        try withTemporaryFile { url in
            var credentials = Credentials()
            credentials["https://store.example.com"] = Credentials.Entry(token: "alleyu_abc")
            try credentials.save(to: url)

            let mode = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.int16Value == 0o600)
        }
    }

    /// 두 번째로 쓸 때 권한이 풀리면 첫 번째만 안전한 파일이 된다.
    @Test("덮어써도 0600 을 지킨다")
    func rewritingKeepsThePermissions() throws {
        try withTemporaryFile { url in
            var credentials = Credentials()
            credentials["https://store.example.com"] = Credentials.Entry(token: "alleyu_one")
            try credentials.save(to: url)
            credentials["https://store.example.com"] = Credentials.Entry(token: "alleyu_two")
            try credentials.save(to: url)

            let mode = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.int16Value == 0o600)
            #expect(try Credentials.load(from: url)["https://store.example.com"]?.token == "alleyu_two")
        }
    }

    @Test("서버가 여럿이면 각자 따로 남는다")
    func severalServersLiveSideBySide() throws {
        try withTemporaryFile { url in
            var credentials = Credentials()
            credentials["https://a.example.com"] = Credentials.Entry(token: "alleyu_a")
            credentials["https://b.example.com"] = Credentials.Entry(token: "alleyu_b")
            try credentials.save(to: url)

            let read = try Credentials.load(from: url)
            #expect(read["https://a.example.com"]?.token == "alleyu_a")
            #expect(read["https://b.example.com"]?.token == "alleyu_b")
            #expect(read.onlyServer == nil)
        }
    }

    /// 붙은 서버가 하나면 주소를 다시 적게 하지 않는다.
    @Test("하나뿐이면 그것을 기본으로 본다")
    func aSingleServerIsTheDefault() throws {
        var credentials = Credentials()
        credentials["https://store.example.com/"] = Credentials.Entry(token: "alleyu_abc")

        let only = try #require(credentials.onlyServer)
        // 뒤 슬래시는 키에서 떨어진다. 안 그러면 같은 서버가 둘로 남는다.
        #expect(only.server == "https://store.example.com")
    }

    @Test("없는 파일은 빈 것으로 읽는다")
    func aMissingFileIsEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alley-nope-\(UUID().uuidString)")
        #expect(try Credentials.load(from: url).entries.isEmpty)
    }
}

/// 어디서 무엇을 읽어 쓰는지 (ADR-0064).
@Suite("CLI 설정 읽기")
struct CLIConfigSourceTests {
    private func withStored(_ token: String, server: String, _ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alley-conf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("credentials")
        var credentials = Credentials()
        credentials[server] = Credentials.Entry(token: token)
        try credentials.save(to: url)
        try body(url)
    }

    @Test("저장해둔 것으로 붙는다")
    func theStoredTokenIsUsed() throws {
        try withStored("alleyu_stored", server: "https://store.example.com") { url in
            let config = try CLIConfig.load(from: [:], credentialsAt: url)
            #expect(config.token == "alleyu_stored")
            #expect(config.serverURL.absoluteString == "https://store.example.com")
        }
    }

    /// CI 는 사람이 앉아 있지 않아 브라우저를 열 수 없다. 거기서는 환경변수가 답이다.
    @Test("환경변수가 저장해둔 것보다 먼저다")
    func theEnvironmentWins() throws {
        try withStored("alleyu_stored", server: "https://store.example.com") { url in
            let config = try CLIConfig.load(
                from: [
                    "ALLEY_SERVER_URL": "https://store.example.com",
                    "ALLEY_TOKEN": "alleyd_from_ci",
                ],
                credentialsAt: url
            )
            #expect(config.token == "alleyd_from_ci")
        }
    }

    @Test("붙여둔 것도 환경변수도 없으면 무엇이 필요한지 말한다")
    func nothingStoredSaysWhatToDo() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alley-none-\(UUID().uuidString)")
        #expect(throws: CLIConfig.ConfigError.self) {
            try CLIConfig.load(from: [:], credentialsAt: url)
        }
    }
}

/// 기기 이름 (ADR-0064).
@Suite("기기 이름")
struct DeviceNameTests {
    @Test("호스트명 뒤에 꼬리를 붙인다")
    func theHostnameGetsASuffix() {
        #expect(AuthCommand.deviceName(host: "my-mac", suffix: "a3f9") == "my-mac-a3f9")
    }

    /// `.local` 은 모두가 같아서 구별에 보태는 것이 없다.
    @Test("`.local` 은 뗀다")
    func theLocalSuffixIsDropped() {
        #expect(AuthCommand.deviceName(host: "my-mac.local", suffix: "a3f9") == "my-mac-a3f9")
    }

    /// 같은 맥에서 두 번 연결해도 목록에서 구별돼야 폐기할 것을 고를 수 있다.
    @Test("두 번 부르면 다른 이름이 나온다")
    func twoConnectionsGetDifferentNames() {
        #expect(AuthCommand.deviceName(host: "my-mac") != AuthCommand.deviceName(host: "my-mac"))
    }

    @Test("호스트명이 없으면 그래도 이름이 있다")
    func anEmptyHostStillGetsAName() {
        #expect(AuthCommand.deviceName(host: "", suffix: "a3f9") == "alley CLI-a3f9")
    }
}

/// 브라우저가 돌려보내는 요청을 읽는 자리 (ADR-0064).
@Suite("루프백 콜백")
struct LoopbackListenerTests {
    @Test("첫 줄에서 주소를 꺼낸다")
    func theTargetComesFromTheRequestLine() {
        let request = "GET /?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(LoopbackListener.requestTarget(request) == "/?code=abc&state=xyz")
    }

    /// 브라우저는 303 을 GET 으로 따라간다. 다른 것이 오면 우리가 기다리던 것이 아니다.
    @Test("GET 이 아니면 읽지 않는다")
    func onlyGetIsRead() {
        #expect(LoopbackListener.requestTarget("POST /?code=abc HTTP/1.1\r\n\r\n") == nil)
    }

    @Test("빈 요청은 읽지 않는다")
    func anEmptyRequestIsIgnored() {
        #expect(LoopbackListener.requestTarget("") == nil)
    }
}
