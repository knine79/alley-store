import Foundation

/// 아주 작은 인자 파서.
///
/// `swift-argument-parser` 를 쓰지 않는다. CI 에서 도는 도구라 의존성 하나가
/// 늘어나는 것이 그대로 빌드 시간과 공급망 표면이 된다. 지금 필요한 문법은
/// `--키 값` 과 `--깃발` 두 가지뿐이다.
public struct Arguments: Sendable {
    public enum ParseError: Error, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)
        case notANumber(option: String, value: String)

        public var description: String {
            switch self {
            case .unknownOption(let name):
                return "모르는 옵션입니다: \(name)"
            case .missingValue(let name):
                return "\(name) 에 값이 필요합니다."
            case .notANumber(let option, let value):
                return "\(option) 은 숫자여야 합니다: \(value)"
            }
        }
    }

    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    /// 옵션이 아닌 인자. 파일 경로 같은 것.
    public private(set) var positional: [String] = []

    /// - Parameters:
    ///   - valueOptions: 값을 받는 옵션 이름들. 여기 없는 `--이름` 은 깃발로 본다.
    public init(_ raw: [String], valueOptions: Set<String>, flagOptions: Set<String>) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }

            let name = String(argument.dropFirst(2))
            if valueOptions.contains(name) {
                guard let value = iterator.next() else { throw ParseError.missingValue(argument) }
                values[name] = value
            } else if flagOptions.contains(name) {
                flags.insert(name)
            } else {
                throw ParseError.unknownOption(argument)
            }
        }
    }

    public func string(_ name: String) -> String? {
        values[name]
    }

    public func integer(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let value = Int(raw) else {
            throw ParseError.notANumber(option: "--\(name)", value: raw)
        }
        return value
    }

    public func flag(_ name: String) -> Bool {
        flags.contains(name)
    }
}
