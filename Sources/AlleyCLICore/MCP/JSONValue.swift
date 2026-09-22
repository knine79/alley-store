import Foundation

/// 어떤 JSON 값이든 담는 상자.
///
/// MCP 는 도구마다 스키마가 다르고 인자도 도구가 정한다. 그래서 주고받는 값의
/// 타입을 미리 하나로 적을 수 없다. `Codable` 로 왕복할 수 있는 최소한만 만든다.
///
/// 외부 패키지를 들이지 않는 이유는 이 레포의 다른 자리와 같다. CLI 는 워커 맥과
/// CI 에 그대로 옮겨 다니고, 의존이 하나 늘면 그만큼 옮길 것이 늘어난다.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "알 수 없는 JSON 값입니다."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - 꺼내 쓰기

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// 어떤 `Encodable` 이든 JSON 을 거쳐 이 상자로 옮긴다.
    ///
    /// DTO 를 그대로 도구 결과에 실을 때 쓴다. 필드를 손으로 옮겨 적으면 DTO 가
    /// 늘어날 때마다 여기도 고쳐야 하고, 빠뜨린 것은 조용하다.
    public static func encoding(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        return try decoder.decode(JSONValue.self, from: data)
    }
}
