import AlleyShared
import Foundation

/// 이 맥에 이미 깔려 있는 앱 하나.
struct InstalledApp: Equatable, Sendable {
    var bundleID: String
    var shortVersion: String?
    /// `CFBundleVersion` 을 정수로 읽은 것. 정수가 아니면 nil 이다.
    var buildNumber: Int?
    var location: URL
    /// `CFBundleVersion` 원문. `1.8.25` 처럼 점이 들어가도 그대로 둔다 (ADR-0066).
    var bundleVersion: String? = nil
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
            location: bundle,
            bundleVersion: parsed["CFBundleVersion"] as? String
        )
    }
}

/// 깔린 것을 덮어쓰기 전에 띄우는 확인.
enum ReinstallWarning: Equatable {
    /// 깔린 것이 더 새롭다. 누르면 확실히 내려간다.
    case downgrade
    /// 빌드 번호를 못 읽어 견줄 수 없다. 내려갈 수도 있다. "내려간다" 고 단정하면
    /// 틀릴 수 있고, 아무 말도 안 하면 내려갈 때 놀란다.
    case possibleDowngrade
    /// 같은 빌드다. 잃는 것은 없지만 깔린 것을 지우고 새로 놓는다는 것만 알린다.
    case overwrite

    var title: String {
        switch self {
        case .downgrade: return "이전 버전으로 바뀝니다"
        case .possibleDowngrade: return "이전 버전으로 바뀔 수 있습니다"
        case .overwrite: return "다시 설치할까요?"
        }
    }

    /// 무엇이 무엇으로 바뀌는지 숫자로 적는다. "이전 버전" 만으로는 얼마나
    /// 내려가는지 모른다.
    func message(installed: String, released: String) -> String {
        switch self {
        case .downgrade:
            return "이 맥에 있는 \(installed) 이(가) 스토어의 최신 출시본보다 새롭습니다. "
                + "다시 설치하면 \(released) 로 덮어씁니다."
        case .possibleDowngrade:
            return "이 맥에 있는 \(installed) 와(과) 스토어의 \(released) 중 어느 쪽이 "
                + "새로운지 알 수 없습니다. 다시 설치하면 이전 버전으로 덮어쓸 수 있습니다."
        case .overwrite:
            return "이 맥에 있는 \(installed) 을(를) 덮어씁니다."
        }
    }
}

/// 설치된 것과 출시된 것을 견준 결과.
enum InstallState: Equatable {
    case notInstalled
    /// 아직 출시본이 없어서 받을 것이 없다.
    ///
    /// 개발자와 관리자에게만 보이는 상태다. 일반 사용자에게는 출시본이 있는 앱만
    /// 내려간다 (`AppController.list`). 그런데 그 화면에서도 "설치되지 않음" 이라고
    /// 적혀 있어서, 설치할 수 있는데 안 한 것처럼 읽혔다. 정작 누를 버튼은 없다.
    case notReleased
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
        // 버튼 자체가 안 그려지는 상태다. `InstallButton` 이 출시본이 없으면
        // 아무것도 내놓지 않는다. 여기서는 자리만 채운다.
        case .notReleased: return "설치"
        // 최신이면 받을 것이 없다. 이 줄에 와서 하려는 일은 대개 앱을 여는 것이다.
        // 다시 설치는 깨진 설치를 고칠 때만 쓰므로 버튼의 보조 메뉴로 내린다.
        case .upToDate: return "열기"
        // 더 새로운 것이 깔려 있으면 누르는 순간 출시본으로 내려간다. "열기" 로
        // 적으면 그 일이 숨는다.
        case .ahead, .unknown: return "다시 설치"
        }
    }

    /// 버튼이 앱을 여는가, 받는가.
    var opensInstalledApp: Bool { self == .upToDate }

    /// 깔린 것을 갈아끼운 뒤 알리는 말. `self` 는 받기 **전** 상태다.
    ///
    /// 전부 "업데이트했습니다" 라고 하면 내려간 경우에도 올라간 것처럼 읽힌다.
    /// 올라갔는지 모르는 경우(`unknown`)와 같은 빌드를 다시 받은 경우는 한 일
    /// 그대로 "다시 설치" 라고 적는다.
    func replacedMessage(appName: String, version: String) -> String {
        switch self {
        case .updateAvailable:
            return "\(appName) 을(를) \(version) 로 업데이트했습니다."
        case .ahead:
            return "\(appName) 을(를) \(version) 로 되돌렸습니다."
        case .upToDate, .unknown, .notInstalled, .notReleased:
            return "\(appName) 을(를) \(version) 로 다시 설치했습니다."
        }
    }

    /// 받기 전에 물어야 하는 것. 이미 깔린 것을 덮어쓰는 상태에서만 있다.
    ///
    /// 깔린 것은 덮어쓰면 되돌릴 수 없다. 스토어에 없는 빌드(개발자가 직접 넣은
    /// 것)일 수 있어서다. 무엇을 잃는지는 상태마다 달라서 말도 다르게 한다.
    var reinstallWarning: ReinstallWarning? {
        switch self {
        case .ahead: return .downgrade
        case .unknown: return .possibleDowngrade
        case .upToDate: return .overwrite
        case .notInstalled, .notReleased, .updateAvailable: return nil
        }
    }

    var summary: String {
        switch self {
        case .notInstalled: return "설치되지 않음"
        case .notReleased: return "출시본 없음"
        case .upToDate: return "최신"
        case .updateAvailable: return "업데이트 있음"
        case .ahead: return "설치된 것이 더 최신"
        case .unknown: return "설치됨"
        }
    }
}

extension InstallState {
    /// 깔린 번들과 출시본을 견준다 (ADR-0066).
    ///
    /// **번들에 적힌 값끼리 견준다.** 스토어의 빌드 번호는 스토어가 앱 안에서 매기는
    /// 정수라, 번들의 `CFBundleVersion` 과 같다는 보장이 없다. 그 전제로 견주면
    /// `CFBundleVersion` 이 `1.8.25` 인 앱은 영영 "비교 불가" 가 되고, 정수라도 스토어가
    /// 1 을 매겼으면 "깔린 것이 더 새롭다" 가 된다.
    ///
    /// 서버가 번들 값을 모를 때(이 칸이 생기기 전에 서명한 버전, 예전 서버)는 지금까지처럼
    /// 정수 빌드 번호로, 그것도 안 되면 버전 문자열로 견준다. 이미 출시된 앱을 다시
    /// 올리지 않아도 "열기" 가 되게 하려는 폴백이다.
    static func compare(installed: InstalledApp?, released: VersionDTO?) -> InstallState {
        guard let installed else {
            return released == nil ? .notReleased : .notInstalled
        }
        guard let released else { return .unknown }

        if let theirs = released.bundleVersion, let ours = installed.bundleVersion {
            return order(ours, theirs)
        }
        if released.bundleVersion == nil, installed.buildNumber != nil {
            return compare(installed: installed, releasedBuild: released.buildNumber)
        }
        if let ours = installed.shortVersion {
            return order(ours, released.shortVersion)
        }
        return .unknown
    }

    /// `1.8.25` 같은 값을 앞에서부터 숫자로 견준다.
    ///
    /// 같은 문자열이면 최신이다. 모자란 자리는 0 으로 본다(`1.8` 은 `1.8.0`). 숫자가
    /// 아닌 조각이 있으면 견주지 않는다. 짐작해서 "업데이트 있음" 이라고 하면 받은 뒤에도
    /// 같은 표시가 남는다.
    static func order(_ installed: String, _ released: String) -> InstallState {
        if installed == released { return .upToDate }
        let parse: (String) -> [Int]? = { value in
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
        }
        guard let ours = parse(installed), let theirs = parse(released) else { return .unknown }
        for index in 0..<max(ours.count, theirs.count) {
            let a = index < ours.count ? ours[index] : 0
            let b = index < theirs.count ? theirs[index] : 0
            if a < b { return .updateAvailable }
            if a > b { return .ahead }
        }
        return .upToDate
    }

    /// 빌드 번호로만 비교한다.
    ///
    /// 버전 문자열(`1.0.0`)은 사람이 정하는 값이라 앱마다 규칙이 다르고, 되돌아가는
    /// 경우도 있다. 빌드 번호는 같은 앱 안에서 유일하고 단조 증가한다는 것을 서버가
    /// 보장하므로(`versions` 의 유일 제약) 이쪽이 믿을 수 있다.
    static func compare(installed: InstalledApp?, releasedBuild: Int?) -> InstallState {
        // 깔려 있지도 않고 출시본도 없으면 받을 것이 없다. 이것을 "설치되지 않음"
        // 으로 뭉뚱그리면 목록은 설치할 수 있다고 말하는데 버튼은 없는 화면이 된다.
        guard let installed else {
            return releasedBuild == nil ? .notReleased : .notInstalled
        }
        guard let releasedBuild, let current = installed.buildNumber else { return .unknown }

        if current < releasedBuild { return .updateAvailable }
        if current > releasedBuild { return .ahead }
        return .upToDate
    }
}
