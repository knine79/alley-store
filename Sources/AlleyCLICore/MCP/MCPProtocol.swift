import Foundation

/// MCP 가 주고받는 JSON-RPC 한 줄.
///
/// stdio 전송은 줄 단위다. 한 줄에 메시지 하나가 오고, 한 줄에 하나를 내보낸다.
/// LSP 처럼 `Content-Length` 헤더를 쓰지 않는다.
struct RPCMessage: Decodable {
    var jsonrpc: String?
    /// 알림(notification)에는 없다. 그때는 답하지 않는다.
    var id: JSONValue?
    var method: String?
    var params: JSONValue?
}

/// 돌려줄 한 줄.
struct RPCResponse: Encodable {
    var jsonrpc = "2.0"
    var id: JSONValue
    var result: JSONValue?
    var error: RPCError?

    static func ok(id: JSONValue, _ result: JSONValue) -> RPCResponse {
        RPCResponse(id: id, result: result, error: nil)
    }

    static func failed(id: JSONValue, code: Int, message: String) -> RPCResponse {
        RPCResponse(id: id, result: nil, error: RPCError(code: code, message: message))
    }
}

struct RPCError: Encodable {
    var code: Int
    var message: String

    /// JSON-RPC 가 정해둔 값들. 우리가 쓰는 것만 적는다.
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// 도구 하나의 생김새.
///
/// 이름과 설명, 그리고 인자의 스키마다. 에이전트는 이 셋만 보고 부를지 정하므로
/// 설명에 "언제 쓰는 것인지" 까지 적는다. 이름만 보고 고르게 두면 엉뚱한 것을
/// 부른다.
struct MCPTool: Sendable {
    var name: String
    var description: String
    /// JSON Schema. 인자가 없으면 빈 object.
    var inputSchema: JSONValue

    func toJSON() -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }

    /// 문자열 인자 몇 개짜리 스키마를 짧게 적는다.
    static func schema(
        required: [String: String] = [:],
        optional: [String: String] = [:]
    ) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for (name, description) in required.merging(optional, uniquingKeysWith: { first, _ in first }) {
            properties[name] = .object([
                "type": .string("string"),
                "description": .string(description),
            ])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.keys.sorted().map(JSONValue.string)),
        ])
    }
}

/// 도구가 내놓는 결과.
///
/// MCP 는 결과를 `content` 배열로 받는다. 우리가 내는 것은 언제나 글 한 덩어리이고,
/// 구조가 있는 값은 그 안에 JSON 으로 담는다.
enum MCPToolResult {
    static func text(_ value: String) -> JSONValue {
        .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(value)])
            ])
        ])
    }

    /// 실패도 예외가 아니라 결과로 돌려준다.
    ///
    /// **JSON-RPC 오류로 답하지 않는다.** 그쪽은 "부를 수 없는 요청" 을 위한 자리다.
    /// 서명이 실패했다거나 권한이 없다는 것은 에이전트가 읽고 다음 수를 정해야 하는
    /// 사실이라, 오류로 던지면 그 사실이 모델에게 닿지 않고 도구 호출만 깨진다.
    static func failure(_ value: String) -> JSONValue {
        .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(value)])
            ]),
            "isError": .bool(true),
        ])
    }

    static func json(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return text(String(decoding: data, as: UTF8.self))
    }
}
