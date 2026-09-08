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

    /// Electron 을 품고 있는지.
    ///
    /// 경로 하나만 본다. Electron 앱은 예외 없이 이 자리에 프레임워크를 놓는다.
    /// 이 프레임워크가 있으면 그 앱은 V8 을 띄우고, Hardened Runtime 아래에서 JIT 권한
    /// 없이는 실행되자마자 죽는다.
    public var containsElectronFramework: Bool {
        FileManager.default.fileExists(
            atPath: url
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
                .path
        )
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
    /// 중첩 번들(프레임워크, 확장, 헬퍼 앱)과, 어느 번들의 주 실행 파일도 아닌 Mach-O
    /// 파일이다. 주 실행 파일만 그 번들을 서명할 때 함께 봉인된다. 나머지는 번들 **안에**
    /// 있더라도 자기 서명이 필요하다.
    ///
    /// 이 구분이 중요한 이유는 프레임워크가 실제로 그렇게 생겼기 때문이다. Electron 은
    /// `Electron Framework.framework/Versions/A/Libraries/` 에 dylib 을 넣고
    /// `Helpers/chrome_crashpad_handler` 를 함께 담는다. Squirrel 은 `Resources/ShipIt`
    /// 을 담는다. 프레임워크를 서명해도 이것들의 서명은 바뀌지 않는다. 링커가 붙여둔
    /// ad-hoc 서명이 그대로 남고, 공증에서 Developer ID 로 서명되지 않은 코드로 걸린다.
    func nestedCode() throws -> [URL] {
        let bundleExtensions: Set<String> = [
            "framework", "app", "appex", "xpc", "bundle", "systemextension",
        ]
        let libraryExtensions: Set<String> = ["dylib", "so"]

        var found: [URL] = []
        // 지금까지 만난 중첩 번들. 어느 번들이 이 파일을 품고 있는지 찾는 데 쓴다.
        var bundles: [(relativePath: String, mainExecutables: Set<String>)] = []
        let ownMainExecutables = Self.mainExecutablePaths(of: url)

        walk { entry, relativePath, isDirectory in
            if bundleExtensions.contains(entry.pathExtension) {
                bundles.append((relativePath, Self.mainExecutablePaths(of: entry)))
                found.append(entry)
                return
            }
            guard !isDirectory else { return }

            let isCode = libraryExtensions.contains(entry.pathExtension)
                || Self.isMachO(at: entry)
            guard isCode else { return }

            // 이 파일을 품은 가장 안쪽 번들. 없으면 앱 자신이다.
            let owner = bundles
                .filter { relativePath.hasPrefix($0.relativePath + "/") }
                .max { $0.relativePath.count < $1.relativePath.count }
            let inside = owner.map {
                String(relativePath.dropFirst($0.relativePath.count + 1))
            } ?? relativePath

            // 주 실행 파일은 번들과 함께 봉인된다. 따로 서명하면 그 봉인이 깨진다.
            let mains = owner?.mainExecutables ?? ownMainExecutables
            guard !mains.contains(inside) else { return }
            found.append(entry)
        }

        return found
    }

    /// 번들 안의 모든 Mach-O 파일.
    ///
    /// `codeToSign()` 과 달리 무엇을 서명해야 하는지 따지지 않는다. 서명이 끝난 뒤
    /// **빠뜨린 것이 없는지** 확인하는 쪽에서 쓴다. 서명 대상을 고르는 논리로 검산하면
    /// 그 논리의 실수를 잡을 수 없다.
    public func allMachOFiles() -> [URL] {
        var found: [URL] = []
        walk { entry, _, isDirectory in
            guard !isDirectory, Self.isMachO(at: entry) else { return }
            found.append(entry)
        }
        return found
    }

    /// 번들 안을 위에서 아래로 훑는다. 번들은 그 안의 것보다 먼저 나온다.
    ///
    /// 번들 뿌리에서부터의 상대 경로를 함께 넘긴다. **절대 경로를 비교하지 않으려고
    /// 그렇게 한다.** `FileManager` 는 디렉터리를 훑을 때 링크를 풀어(`/var` 을
    /// `/private/var` 로) 돌려주는데, 같은 Foundation 이 경로를 만들 때는 반대로
    /// `/private` 를 떼는 쪽이라 두 경로가 같은 파일을 가리키면서도 문자열로는
    /// 달라진다. 그 비교에 기대면 조용히 어긋난다.
    ///
    /// 심볼릭 링크는 따라가지도, 넘겨주지도 않는다. `Foo.framework/Foo` 처럼 실체를
    /// 가리키는 링크가 흔한데, 링크를 통해 서명하면 같은 파일을 두 번 서명하게 된다.
    private func walk(
        _ visit: (_ entry: URL, _ relativePath: String, _ isDirectory: Bool) -> Void
    ) {
        var stack: [(directory: URL, prefix: String)] = [(url, "")]
        while let current = stack.popLast() {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: current.directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )) ?? []
            for entry in entries {
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                if values?.isSymbolicLink == true { continue }

                let name = entry.lastPathComponent
                let relativePath = current.prefix.isEmpty
                    ? name : "\(current.prefix)/\(name)"
                let isDirectory = values?.isDirectory == true

                visit(entry, relativePath, isDirectory)
                if isDirectory { stack.append((entry, relativePath)) }
            }
        }
    }

    /// 이 번들의 주 실행 파일 이름.
    ///
    /// `Info.plist` 가 진실이다. 읽을 수 없으면 번들 이름과 같다고 본다. 관례가 그렇고,
    /// 틀려도 그 파일을 한 번 더 서명할 뿐 결과가 깨지지는 않는다.
    var mainExecutableName: String {
        Self.executableName(
            fromInfoPlistAt: url.appendingPathComponent("Contents/Info.plist")
        ) ?? url.deletingPathExtension().lastPathComponent
    }

    /// 이 번들을 서명할 때 함께 봉인되는 주 실행 파일의 경로들. 번들 기준 상대 경로다.
    ///
    /// 하나면 충분할 것 같지만 프레임워크는 그렇지 않다. 버전 디렉터리마다 실행 파일이
    /// 하나씩 있고, 평평한 형태(`Foo.framework/Foo`)도 함께 쓰인다. 어느 쪽이든 그 번들을
    /// 서명할 때 봉인되므로 전부 모아서 돌려준다.
    ///
    /// 여기에 실제로 없는 경로가 섞여도 손해가 없다. 그 경로에는 파일이 없으니 비교에
    /// 걸리지 않는다. 반대로 **빠뜨리면 같은 파일을 두 번 서명하게 되어** 바깥 번들의
    /// 봉인이 깨진다. 그래서 넉넉하게 모은다.
    static func mainExecutablePaths(of bundle: URL) -> Set<String> {
        let fallback = bundle.deletingPathExtension().lastPathComponent

        guard bundle.pathExtension == "framework" else {
            let name = executableName(
                fromInfoPlistAt: bundle.appendingPathComponent("Contents/Info.plist")
            ) ?? fallback
            return ["Contents/MacOS/\(name)"]
        }

        // 평평한 형태.
        var paths: Set<String> = [fallback]

        let versions = bundle.appendingPathComponent("Versions", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: versions, includingPropertiesForKeys: nil
        )) ?? []
        for version in entries {
            let name = executableName(
                fromInfoPlistAt: version.appendingPathComponent("Resources/Info.plist")
            ) ?? fallback
            paths.insert("Versions/\(version.lastPathComponent)/\(name)")
        }
        return paths
    }

    /// `Info.plist` 의 `CFBundleExecutable`.
    static func executableName(fromInfoPlistAt plist: URL) -> String? {
        string("CFBundleExecutable", fromInfoPlistAt: plist)
    }

    /// 이 번들이 자기라고 밝히는 번들 ID.
    ///
    /// 없을 수 있다. 그때는 이 zip 이 앱 번들 꼴을 하고 있을 뿐 macOS 가 앱으로
    /// 다루지 않는다는 뜻이다. 판단은 부르는 쪽에 맡긴다.
    public var bundleIdentifier: String? {
        Self.string(
            "CFBundleIdentifier",
            fromInfoPlistAt: url.appendingPathComponent("Contents/Info.plist")
        )
    }

    /// `Info.plist` 에서 문자열 값 하나를 읽는다.
    ///
    /// XML 과 바이너리 plist 를 모두 읽는다. `PropertyListSerialization` 이 앞머리를
    /// 보고 스스로 가른다. 실제 앱은 대부분 바이너리로 들어 있다.
    static func string(_ key: String, fromInfoPlistAt plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let value = parsed[key] as? String
        else {
            return nil
        }
        return value
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
