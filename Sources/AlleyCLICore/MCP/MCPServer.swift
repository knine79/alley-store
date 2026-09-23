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
        write: @escaping @Sendable (String) -> Void = MCPServer.writeLine,
        complain: @escaping @Sendable (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) {
        self.api = api
        self.write = write
        self.complain = complain
    }

    /// 한 줄을 표준 출력으로 내보낸다.
    ///
    /// **`print` 를 쓰지 않는다.** 표준 출력이 파이프면 libc 가 블록 단위로 모았다가
    /// 내보내고, 그 버퍼는 프로세스가 끝날 때까지 비지 않는다. 우리 쪽은 답을 다
    /// 만들어놓고 상대는 아무것도 못 받은 채 핸드셰이크에서 시간을 다 쓴다. 붙는
    /// 상대가 언제나 파이프라서 이 경로에서는 늘 그렇게 된다. 워커도 같은 이유로
    /// `FileHandle` 에 직접 쓴다.
    public static func writeLine(_ line: String) {
        // 요청을 나란히 처리하므로 두 응답이 같은 순간에 나갈 수 있다. 섞이면 두 줄
        // 다 읽을 수 없는 것이 된다.
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static let outputLock = NSLock()

    /// 표준 입력이 닫힐 때까지 한 줄씩 처리한다.
    ///
    /// **읽는 것과 처리하는 것을 나눈다.** 한 줄을 끝까지 처리하고 다음 줄을 읽으면,
    /// 한 시간 걸리는 업로드 동안 상대가 보낸 `ping` 과 취소가 파이프에 쌓인 채
    /// 읽히지 않는다. 그 사이에 상대는 서버가 죽었다고 보고 프로세스를 끊는다.
    ///
    /// 읽기는 전용 스레드에서 한다. `readLine` 은 값이 올 때까지 돌아오지 않는데,
    /// 그것을 async 함수 안에서 그대로 부르면 협력 스레드 하나가 그동안 묶인다
    /// (`Shell.runDetached` 가 같은 이유로 같은 일을 한다).
    public func run() async {
        let lines = AsyncStream<String> { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = "alley-mcp-stdin"
            thread.start()
        }

        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                group.addTask { await handleLine(line) }
            }
            await group.waitForAll()
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
        } catch let error as MCPToolbox.ToolError where error.isProtocolViolation {
            // 없는 도구를 부르는 것은 규약을 어긴 것이다. 모델이 고쳐 쓸 것이 아니라
            // 붙어 있는 쪽이 도구 목록을 잘못 읽은 것이다.
            send(.failed(id: id, code: RPCError.invalidParams, message: String(describing: error)))
        } catch {
            // **나머지는 결과로 돌려준다.** 앱 이름을 잘못 적었다거나 서명이
            // 실패했다는 것은 모델이 읽고 다음 수를 정해야 하는 사실이다. JSON-RPC
            // 오류로 던지면 그 사실이 모델에 닿지 않고 도구 호출만 깨진다.
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
