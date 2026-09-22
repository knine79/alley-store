import AlleyShared
import Foundation

/// 코딩 에이전트에게 스토어를 내주는 MCP 서버 (ADR-0060).
///
/// **릴리스 한 번을 내는 동안 사람이 자리를 여러 번 옮긴다.** 올리고, 콘솔을
/// 새로고침하며 서명을 기다리고, 실패하면 화면의 안내를 읽어 손으로 고치고,
/// Sparkle 값을 복사해 `Info.plist` 에 붙인다. 그 자리를 에이전트가 밟게 한다.
///
/// 전송은 stdio 다. 한 줄에 JSON-RPC 메시지 하나가 오고, 한 줄로 답한다.
/// **표준 출력에는 이 메시지만 나가야 한다.** 로그 한 줄이 섞이면 붙어 있던
/// 에이전트가 그 줄을 파싱하려다 끊는다. 그래서 알릴 것은 전부 표준 오류로 간다.
public struct MCPServer: Sendable {
    /// 우리가 말할 줄 아는 규약 판. 상대가 다른 것을 말해도 우리 것을 돌려준다.
    static let protocolVersion = "2025-06-18"

    private let api: StoreAPI
    private let write: @Sendable (String) -> Void
    private let complain: @Sendable (String) -> Void

    public init(
        api: StoreAPI,
        write: @escaping @Sendable (String) -> Void = { print($0) },
        complain: @escaping @Sendable (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) {
        self.api = api
        self.write = write
        self.complain = complain
    }

    /// 표준 입력이 닫힐 때까지 한 줄씩 처리한다.
    public func run() async {
        while let line = readLine(strippingNewline: true) {
            await handleLine(line)
        }
    }

    /// 한 줄을 처리하고, 답할 것이 있으면 내보낸다.
    ///
    /// 테스트가 이 자리를 부른다. 표준 입출력을 잡지 않고도 규약을 확인할 수 있어야
    /// 한다.
    public func handleLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONDecoder().decode(RPCMessage.self, from: data)
        else {
            complain("읽을 수 없는 줄을 건너뜁니다.")
            return
        }

        // 알림에는 답하지 않는다. `notifications/initialized` 가 그렇게 온다.
        guard let id = message.id else { return }
        guard let method = message.method else {
            send(.failed(id: id, code: RPCError.invalidParams, message: "method 가 없습니다."))
            return
        }

        switch method {
        case "initialize":
            send(.ok(id: id, initializeResult()))

        case "ping":
            send(.ok(id: id, .object([:])))

        case "tools/list":
            send(.ok(id: id, .object(["tools": .array(MCPToolbox.all.map { $0.toJSON() })])))

        case "tools/call":
            await callTool(message.params, id: id)

        default:
            send(.failed(id: id, code: RPCError.methodNotFound, message: "모르는 method 입니다: \(method)"))
        }
    }

    private func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string("alley"),
                "version": .string(CLI.version),
            ]),
        ])
    }

    private func callTool(_ params: JSONValue?, id: JSONValue) async {
        guard let name = params?["name"]?.stringValue else {
            send(.failed(id: id, code: RPCError.invalidParams, message: "도구 이름이 없습니다."))
            return
        }
        let arguments = params?["arguments"]?.objectValue ?? [:]

        do {
            let result = try await MCPToolbox.run(name, arguments: arguments, api: api)
            send(.ok(id: id, result))
        } catch let error as MCPToolbox.ToolError {
            // 모르는 도구는 규약 오류다. 나머지는 결과로 돌려준다.
            send(.failed(id: id, code: RPCError.invalidParams, message: String(describing: error)))
        } catch {
            // **실패를 결과로 돌려준다.** 서명이 실패했다거나 권한이 없다는 것은
            // 에이전트가 읽고 다음 수를 정해야 하는 사실이다. JSON-RPC 오류로
            // 던지면 그 사실이 모델에 닿지 않고 도구 호출만 깨진다.
            send(.ok(id: id, MCPToolResult.failure(String(describing: error))))
        }
    }

    private func send(_ response: RPCResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(response) else {
            complain("응답을 만들지 못했습니다.")
            return
        }
        write(String(decoding: data, as: UTF8.self))
    }
}
