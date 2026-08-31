import Foundation

/// 이 맥에 이미 깔려 있는 앱 하나.
struct InstalledApp: Equatable, Sendable {
    var bundleID: String
    var shortVersion: String?
    /// `CFBundleVersion`. 스토어의 빌드 번호와 같은 값이라 이것으로 최신 여부를 판단한다.
    var buildNumber: Int?
    var location: URL
}

/// 설치된 앱을 찾는다.
///
/// 앱이 스스로 "설치됨"을 기록해두지 않는다. 사용자가 Finder 로 지우거나 다른 경로에서
/// 받아 넣을 수 있어서, 우리가 남긴 기록은 금방 사실과 어긋난다. 매번 디스크를 본다.
enum InstalledApps {
    /// 앱이 있을 만한 자리.
    ///
    /// `/Applications` 와 `~/Applications` 만 본다. 시스템 전체를 뒤지면 느리고,
    /// 사내 앱을 다른 곳에 두는 경우는 드물다.
    static func searchPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// 주어진 디렉터리들에서 앱을 훑어 번들 ID 로 묶는다.
    ///
    /// 같은 앱이 두 곳에 있으면 `/Applications` 쪽을 남긴다. 목록 순서가 곧 우선순위다.
    static func scan(directories: [URL]) -> [String: InstalledApp] {
        var found: [String: InstalledApp] = [:]

        for directory in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []

            for candidate in contents where candidate.pathExtension == "app" {
                guard let app = read(bundle: candidate) else { continue }
                // 먼저 본 자리가 이긴다.
                if found[app.bundleID] == nil {
                    found[app.bundleID] = app
                }
            }
        }
        return found
    }

    static func scan() -> [String: InstalledApp] {
        scan(directories: searchPaths())
    }

    /// 번들의 `Info.plist` 를 읽는다.
    static func read(bundle: URL) -> InstalledApp? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let bundleID = parsed["CFBundleIdentifier"] as? String
        else {
            return nil
        }

        return InstalledApp(
            bundleID: bundleID,
            shortVersion: parsed["CFBundleShortVersionString"] as? String,
            // 빌드 번호는 관례상 정수지만 형식이 강제되지 않는다. 숫자로 못 읽으면 없는 셈 친다.
            buildNumber: (parsed["CFBundleVersion"] as? String).flatMap(Int.init),
            location: bundle
        )
    }
}

/// 설치된 것과 출시된 것을 견준 결과.
enum InstallState: Equatable {
    case notInstalled
    case upToDate
    case updateAvailable
    /// 깔려 있는 것이 스토어의 출시본보다 새롭다. 개발자가 직접 넣은 빌드일 수 있다.
    case ahead
    /// 빌드 번호를 읽지 못해 비교할 수 없다.
    case unknown

    var actionTitle: String {
        switch self {
        case .notInstalled: return "설치"
        case .updateAvailable: return "업데이트"
        case .upToDate, .ahead, .unknown: return "다시 설치"
        }
    }

    var summary: String {
        switch self {
        case .notInstalled: return "설치되지 않음"
        case .upToDate: return "최신"
        case .updateAvailable: return "업데이트 있음"
        case .ahead: return "설치된 것이 더 최신"
        case .unknown: return "설치됨"
        }
    }
}

extension InstallState {
    /// 빌드 번호로만 비교한다.
    ///
    /// 버전 문자열(`1.0.0`)은 사람이 정하는 값이라 앱마다 규칙이 다르고, 되돌아가는
    /// 경우도 있다. 빌드 번호는 같은 앱 안에서 유일하고 단조 증가한다는 것을 서버가
    /// 보장하므로(`versions` 의 유일 제약) 이쪽이 믿을 수 있다.
    static func compare(installed: InstalledApp?, releasedBuild: Int?) -> InstallState {
        guard let installed else { return .notInstalled }
        guard let releasedBuild, let current = installed.buildNumber else { return .unknown }

        if current < releasedBuild { return .updateAvailable }
        if current > releasedBuild { return .ahead }
        return .upToDate
    }
}
