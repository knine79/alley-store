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
        // 인자가 빠진 것은 모델이 다시 부르면 되는 일이라 결과로 돌려준다.
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"] == .bool(true))
    }

    /// 규약을 어긴 것과 모델이 고칠 수 있는 것을 가른다. 후자를 오류로 던지면 그
    /// 사실이 모델에 닿지 않고 도구 호출만 깨진다.
    @Test("고칠 수 있는 실패는 결과로 온다")
    func recoverableFailuresComeBackAsResults() async throws {
        let response = try #require(
            await ask(
                #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"signing_status","arguments":{"version":"버전아님"}}}"#
            )
        )
        // 오류가 아니라 결과다. 내용에 무엇이 잘못됐는지가 들어 있다.
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"] == .bool(true))
    }

    // MARK: - 앱 상세 (이슈 #70)

    /// 서버에 닿기 전에 인자에서 걸러지는 것만 본다. 앱 이름을 풀려면 서버가 필요해서
    /// 앱 id 자리에도 무엇이든 넣는다. 그 전에 막혀야 하는 것들이다.
    private func call(_ tool: String, _ arguments: String) async throws -> [String: JSONValue] {
        try #require(
            await ask(
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":""# + tool
                    + #"","arguments":"# + arguments + "}}"
            )
        )
    }

    @Test("앱 상세 도구를 낸다")
    func listsAppDetailTools() async throws {
        let response = try #require(await ask(#"{"jsonrpc":"2.0","id":8,"method":"tools/list"}"#))
        guard case .array(let tools)? = response["result"]?["tools"] else {
            Issue.record("도구 목록이 배열이 아닙니다.")
            return
        }
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            tool["name"]?.stringValue.map { ($0, tool) }
        })
        for name in ["app_details", "update_app", "add_screenshots", "remove_screenshot", "save_screenshots"] {
            #expect(byName[name] != nil, "\(name) 이 없습니다")
        }
        // 태그와 파일은 배열로 받는다. 쉼표로 이으면 값 안의 쉼표와 구분할 수 없다.
        #expect(byName["update_app"]?["inputSchema"]?["properties"]?["tags"]?["type"] == .string("array"))
        #expect(byName["add_screenshots"]?["inputSchema"]?["properties"]?["files"]?["type"] == .string("array"))
        // 분류는 고를 수 있는 값을 알려준다. 모르면 모델이 지어낸다.
        let category = byName["update_app"]?["inputSchema"]?["properties"]?["category"]?["description"]?.stringValue
        #expect(category?.contains("developer-tools") == true)
    }

    @Test("배열 인자에 배열이 아닌 것을 넣으면 결과로 알린다")
    func listArgumentMustBeStrings() throws {
        #expect(throws: MCPToolbox.ToolError.self) {
            _ = try MCPToolbox.list(named: "tags", in: ["tags": .number(3)])
        }
        #expect(try MCPToolbox.list(named: "tags", in: ["tags": .array([])]) == [])
        // 파일 하나를 배열로 감싸지 않고 보내도 받는다.
        #expect(try MCPToolbox.list(named: "files", in: ["files": .string("/tmp/a.png")]) == ["/tmp/a.png"])
        #expect(try MCPToolbox.list(named: "tags", in: [:]) == nil)
    }

    @Test("스크린샷 주소에서 id 를 꺼낸다")
    func detailsCarryScreenshotIDs() {
        let appID = UUID()
        let shot = UUID()
        let dto = AppDTO(
            id: appID, bundleID: "com.example.notes", name: "메모장",
            screenshotURLs: ["https://store.example.com" + APIPath.appScreenshot(appID, id: shot)],
            ownerID: UUID(), createdAt: Date(), updatedAt: Date()
        )
        let details = AppDetails(dto)
        #expect(details.screenshots == [shot])
        #expect(details.tags == [])
    }

    /// 무엇 때문에 막혔는지까지 본다. 앱을 찾으러 서버에 갔다면 연결 실패가 오고, 그것도
    /// isError 라서 상태만 보면 구별되지 않는다.
    @Test("고칠 항목이 없거나 경로가 상대 경로면 서버에 가기 전에 막는다")
    func checksArgumentsBeforeCallingServer() async throws {
        func message(_ response: [String: JSONValue]) -> String? {
            response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }
        // 빈 문자열은 넣지 않은 것이다. 지우라는 뜻으로 읽지 않는다.
        let update = try await call("update_app", #"{"app":"com.example.notes","summary":""}"#)
        #expect(update["result"]?["isError"] == .bool(true))
        #expect(message(update)?.contains("바꿀 항목이 없습니다") == true)

        let upload = try await call("add_screenshots", #"{"app":"com.example.notes","files":["shots/a.png"]}"#)
        #expect(message(upload)?.contains("절대 경로") == true)

        let remove = try await call("remove_screenshot", #"{"app":"com.example.notes","screenshot":"첫째"}"#)
        #expect(message(remove)?.contains("id 로 읽을 수 없습니다") == true)
    }

    @Test("읽을 수 없는 줄은 건너뛴다")
    func skipsGarbage() async {
        let response = await ask("이건 JSON 이 아닙니다")
        #expect(response == nil)
    }
}
