import Foundation

/// 번들이 요구하는 권한과, 그것을 서명할 수 있는지에 대한 판단.
///
/// 여기서 걸러내지 않으면 서명은 성공하고 공증까지 통과한 뒤, 사용자의 맥에서
/// 실행할 때가 되어서야 조용히 기능이 동작하지 않는다. 그때는 원인을 찾기 어렵다.
public enum Entitlements {
    /// 프로비저닝 프로필이 있어야 쓸 수 있는 권한인지.
    ///
    /// `com.apple.developer.` 로 시작하는 것들은 Apple 이 팀 단위로 허가하는 기능이라,
    /// 그 허가를 담은 프로필이 번들 안에 들어 있어야 한다. `com.apple.security.` 로
    /// 시작하는 샌드박스·하드닝 관련 권한은 프로필 없이도 서명할 수 있다.
    public static func isRestricted(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.")
    }

    public static func restricted(in keys: some Sequence<String>) -> [String] {
        keys.filter(isRestricted).sorted()
    }

    /// 번들에 프로비저닝 프로필이 들어 있는지.
    public static func hasProvisioningProfile(in bundle: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/embedded.provisionprofile").path
        )
    }

    /// 이 번들을 지금 서명해도 되는지 판단한다.
    ///
    /// 프로필이 필요한 권한을 쓰는데 프로필이 없으면 여기서 멈춘다. 그대로 서명하면
    /// codesign 이 권한을 조용히 떨어뜨리거나, 설치한 뒤 그 기능만 동작하지 않는다.
    public static func validate(bundle: URL, declaredKeys: [String]) throws {
        let restricted = restricted(in: declaredKeys)
        guard !restricted.isEmpty else { return }
        guard !hasProvisioningProfile(in: bundle) else { return }

        throw ValidationError.missingProfile(
            bundle: bundle.lastPathComponent,
            keys: restricted
        )
    }

    public enum ValidationError: Error, CustomStringConvertible {
        case missingProfile(bundle: String, keys: [String])

        public var description: String {
            switch self {
            case .missingProfile(let bundle, let keys):
                return """
                    \(bundle) 은 프로비저닝 프로필이 필요한 권한을 쓰는데 프로필이 들어 있지 \
                    않습니다: \(keys.joined(separator: ", ")). Xcode 에서 Developer ID 프로필을 \
                    포함해 빌드하거나, 해당 권한을 빼고 다시 올리세요.
                    """
            }
        }
    }

    // MARK: - 번들에서 읽기

    /// 번들에 붙어 있는 권한 목록을 plist 원문 그대로 읽는다.
    ///
    /// 서명이 없는 번들에서는 읽을 것이 없어서 빈 데이터가 나온다. 그건 오류가 아니다.
    /// 권한을 전혀 안 쓰는 앱이 대부분이다.
    public static func read(of bundle: URL) async -> Data {
        let result = await Shell.runDetached(
            "/usr/bin/codesign",
            ["-d", "--entitlements", ":-", "--xml", bundle.path],
            timeout: 60
        )
        guard result.succeeded else { return Data() }
        return Data(result.standardOutput.utf8)
    }

    /// plist 에서 최상위 키만 뽑는다.
    public static func keys(fromPropertyList data: Data) -> [String] {
        guard !data.isEmpty,
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let dictionary = parsed as? [String: Any]
        else {
            return []
        }
        return dictionary.keys.sorted()
    }

    /// 읽어둔 권한을 codesign 에 다시 넘길 파일로 쓴다.
    ///
    /// **다시 넘기지 않으면 권한이 사라진다.** `codesign` 은 재서명할 때 이전 권한을
    /// 물려주지 않는다. 그래서 지금 붙어 있는 것을 그대로 꺼내 파일로 만들어 넘긴다.
    /// 권한이 없으면 nil 을 주고, 그때는 `--entitlements` 없이 서명한다.
    public static func writePropertyList(_ data: Data, to file: URL) -> URL? {
        guard !keys(fromPropertyList: data).isEmpty else { return nil }
        do {
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
