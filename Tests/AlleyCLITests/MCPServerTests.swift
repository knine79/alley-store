import AlleyShared
import Foundation
import Testing

@testable import AlleyCLICore

/// MCP 규약을 지키는지 (ADR-0060).
///
/// **붙는 쪽은 사람이 아니라 프로그램이다.** 한 줄이라도 형식이 어긋나면 에이전트가
/// 그 자리에서 끊고, 사람은 "MCP 서버가 안 뜬다" 만 본다. 여기서 보는 것은 서버에
/// 붙지 않고도 확인할 수 있는 규약 쪽이다. 실제 호출 결과는 서버 테스트가 본다.
@Suite("MCP 서버")
struct MCPServerTests {
    /// 한 줄을 넣고 돌아온 줄을 JSON 으로 돌려준다.
    private func ask(_ line: String) async -> [String: JSONValue]? {
        let collected = Collector()
        let server = MCPServer(
            api: StoreAPI(
                config: CLIConfig(serverURL: URL(string: "https://store.example.com")!, token: "alleyu_test")
            ),
            write: { collected.append($0) },
            complain: { _ in }
        )
        await server.handleLine(line)
        guard let out = collected.lines.first,
              let data = out.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return nil
        }
        return value.objectValue
    }

    private final class Collector: @unchecked Sendable {
        private(set) var lines: [String] = []
        private let lock = NSLock()
        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }
    }

    @Test("초기화에 규약 판과 서버 이름을 돌려준다")
    func initializeHandshake() async throws {
        let response = try #require(
            await ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        )
        let result = try #require(response["result"]?.objectValue)
        #expect(result["protocolVersion"]?.stringValue == MCPServer.protocolVersion)
        #expect(result["serverInfo"]?["name"]?.stringValue == "alley")
        // 도구를 낸다고 말해야 에이전트가 tools/list 를 부른다.
        #expect(result["capabilities"]?["tools"] != nil)
    }

    @Test("도구 목록은 이름과 설명과 스키마를 함께 준다")
    func listsTools() async throws {
        let response = try #require(
            await ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        )
        guard case .array(let tools)? = response["result"]?["tools"] else {
            Issue.record("도구 목록이 배열이 아닙니다.")
            return
        }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names.contains("upload_version"))
        #expect(names.contains("signing_status"))
        #expect(names.contains("sparkle_feed"))

        // 설명이 비어 있으면 모델이 언제 쓰는 도구인지 알 수 없다.
        for tool in tools {
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
        }
    }

    @Test("모르는 method 는 -32601 로 답한다")
    func unknownMethod() async throws {
        let response = try #require(
            await ask(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        )
        #expect(response["error"]?["code"] == .number(-32601))
    }

    /// 알림에 답하면 그것이 응답인 줄 알고 짝이 어긋난다.
    @Test("id 없는 알림에는 답하지 않는다")
    func notificationsGetNoReply() async {
        let response = await ask(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(response == nil)
    }

    @Test("모르는 도구는 잘못된 인자로 답한다")
    func unknownTool() async throws {
        let response = try #require(
            await ask(
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_app","arguments":{}}}"#
            )
        )
        #expect(response["error"]?["code"] == .number(-32602))
    }

    /// 서버에 붙기 전에 걸러지는 자리다. 여기서 네트워크를 타면 안 된다.
    @Test("인자가 빠지면 부르기 전에 막는다")
    func missingArgument() async throws {
        let response = try #require(
            await ask(
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"signing_status","arguments":{}}}"#
            )
        )
        #expect(response["error"]?["code"] == .number(-32602))
        #expect(response["error"]?["message"]?.stringValue?.contains("version") == true)
    }

    @Test("읽을 수 없는 줄은 건너뛴다")
    func skipsGarbage() async {
        let response = await ask("이건 JSON 이 아닙니다")
        #expect(response == nil)
    }
}
