import Foundation

/// 서명 대상 앱 번들 하나.
///
/// `codesign` 은 안쪽부터 바깥으로 서명해야 한다. 프레임워크를 서명하기 전에 앱을
/// 서명하면, 프레임워크가 나중에 바뀐 것이 되어 앱의 봉인이 깨진다. Apple 이
/// `--deep` 을 권하지 않는 이유이기도 하다. 그래서 서명할 것들을 우리가 직접 세어서
/// 깊은 것부터 차례로 서명한다.
public struct AppBundle: Sendable {
    /// `.app` 번들의 위치.
    public let url: URL

    public enum BundleError: Error, CustomStringConvertible {
        case notFound(directory: URL)
        case ambiguous(names: [String])

        public var description: String {
            switch self {
            case .notFound(let directory):
                return "\(directory.lastPathComponent) 안에서 .app 번들을 찾지 못했습니다. zip 안에 앱이 있는지 확인하세요."
            case .ambiguous(let names):
                return "zip 안에 .app 번들이 여러 개 있습니다: \(names.joined(separator: ", "))"
            }
        }
    }

    public init(url: URL) {
        self.url = url
    }

    /// 풀어놓은 디렉터리에서 앱을 찾는다.
    ///
    /// 하나만 있어야 한다. 여러 개면 어느 것을 배포할지 우리가 고를 수 없다.
    /// macOS 가 zip 을 만들 때 끼워 넣는 `__MACOSX` 는 건너뛴다.
    public static func locate(in directory: URL) throws -> AppBundle {
        let candidates = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix(".") }

        switch candidates.count {
        case 0: throw BundleError.notFound(directory: directory)
        case 1: return AppBundle(url: candidates[0])
        default: throw BundleError.ambiguous(names: candidates.map(\.lastPathComponent))
        }
    }

    /// 서명해야 하는 것들을 안쪽부터 바깥 순서로.
    ///
    /// 마지막 항목이 언제나 앱 자신이다.
    public func codeToSign() throws -> [URL] {
        let nested = try nestedCode()
            // 깊은 것부터. 같은 깊이끼리의 순서는 상관없다.
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        return nested + [url]
    }

    /// 번들 안에서 따로 서명해야 하는 것들.
    ///
    /// 중첩 번들(프레임워크, 확장, 헬퍼 앱)과 홀로 놓인 Mach-O 파일이다. 번들 안에
    /// 들어 있는 실행 파일은 그 번들을 서명할 때 함께 봉인되므로 여기 넣지 않는다.
    /// 넣으면 같은 것을 두 번 서명하게 된다.
    func nestedCode() throws -> [URL] {
        let bundleExtensions: Set<String> = [
            "framework", "app", "appex", "xpc", "bundle", "systemextension",
        ]
        let libraryExtensions: Set<String> = ["dylib", "so"]

        var found: [URL] = []
        var bundles: [URL] = []

        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else {
            return []
        }

        for case let item as URL in walker {
            let isInsideKnownBundle = bundles.contains { item.path.hasPrefix($0.path + "/") }

            if bundleExtensions.contains(item.pathExtension) {
                bundles.append(item)
                found.append(item)
                continue
            }
            // 프레임워크 안의 실행 파일까지 따로 서명할 필요는 없다.
            guard !isInsideKnownBundle else { continue }

            if libraryExtensions.contains(item.pathExtension) {
                found.append(item)
            } else if Self.isMachO(at: item) {
                found.append(item)
            }
        }

        // 앱의 주 실행 파일은 앱을 서명할 때 함께 서명된다. 같은 디렉터리에 있는
        // 다른 실행 파일은 헬퍼 도구라서 자기 서명이 있어야 하므로 그대로 둔다.
        let main = mainExecutableName
        return found.filter { item in
            !(item.lastPathComponent == main
                && item.deletingLastPathComponent().lastPathComponent == "MacOS")
        }
    }

    /// 이 번들의 주 실행 파일 이름.
    ///
    /// `Info.plist` 가 진실이다. 읽을 수 없으면 번들 이름과 같다고 본다. 관례가 그렇고,
    /// 틀려도 그 파일을 한 번 더 서명할 뿐 결과가 깨지지는 않는다.
    var mainExecutableName: String {
        let fallback = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(
            contentsOf: url.appendingPathComponent("Contents/Info.plist")
        ),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any],
            let name = plist["CFBundleExecutable"] as? String
        else {
            return fallback
        }
        return name
    }

    // MARK: - Mach-O 판별

    /// 파일 앞 4바이트로 실행 파일인지 본다.
    ///
    /// 확장자만으로는 알 수 없다. 헬퍼 도구는 확장자가 없는 경우가 대부분이고,
    /// 그것들은 자기 서명이 없으면 실행되지 않는다.
    static func isMachO(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4) else { return false }
        return isMachO(magic: magic)
    }

    static func isMachO(magic: Data) -> Bool {
        guard magic.count == 4 else { return false }
        let value = magic.reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
        switch value {
        // 32비트·64비트 Mach-O 와 그 바이트 순서가 뒤집힌 형태.
        case 0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE:
            return true
        // 여러 아키텍처를 묶은 universal binary.
        case 0xCAFE_BABE, 0xBEBA_FECA:
            return true
        default:
            return false
        }
    }
}
