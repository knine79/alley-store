import AlleyShared
import AppKit
import Foundation

/// 앱 자동 업데이트 설정 (ADR-0073). 사람마다 자기 맥에 둔다.
///
/// 서버에 두지 않는 이유는 조직이 정할 일이 아니어서다. 앱을 쓰는 중에 바뀌는 것을 싫어하는
/// 사람도, 늘 최신이길 바라는 사람도 있다.
///
/// **스토어 앱 자신은 여기에 없다.** 끌 수 없다. 스토어 앱이 낡으면 다른 앱을 받는 길
/// 자체가 낡는다.
enum UpdatePreferences {
    /// 다른 앱을 묻지 않고 업데이트할지. 계정 메뉴의 "앱 자동 업데이트" 가 이 값이다.
    static let appsKey = "autoUpdateApps"

    /// 기본으로 켠다. 사내 앱은 대개 최신을 쓰는 편이 낫고, 켜두지 않으면 기능이 있어도
    /// 대부분 모른다. 메뉴의 `@AppStorage` 기본값도 이 값과 같아야 한다.
    static let defaultValue = true

    static func autoUpdatesApps(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: appsKey) as? Bool ?? defaultValue
    }

    /// 실행 중이라 물어본 업데이트. 번들 ID → 물어본 출시본의 버전 ID (ADR-0074).
    ///
    /// 버전마다 한 번만 묻는다. "나중에" 를 누른 사람에게 30분마다 같은 것을 물으면 결국
    /// 읽지 않고 닫게 된다. 새 버전이 나오면 ID 가 바뀌어 다시 묻는다.
    static let askedRunningKey = "askedRunningUpdates"

    static func askedRunning(_ store: UserDefaults = .standard) -> [String: String] {
        store.dictionary(forKey: askedRunningKey) as? [String: String] ?? [:]
    }

    static func rememberAsked(_ apps: [AppDTO], _ store: UserDefaults = .standard) {
        var asked = askedRunning(store)
        for app in apps {
            guard let version = app.latestReleasedVersion else { continue }
            asked[app.bundleID] = version.id.uuidString
        }
        store.set(asked, forKey: askedRunningKey)
    }
}

/// 묻지 않고 업데이트할 앱을 고른다 (ADR-0073).
enum AutoUpdate {
    /// 자동으로 받을 앱들.
    ///
    /// **업데이트 있음(`updateAvailable`)인 앱만 고른다.** 깔린 것이 스토어보다 새것이거나
    /// 버전을 알 수 없으면 사람이 누를 때도 덮어쓸지 묻는다 (`reinstallWarning`). 개발자가
    /// 직접 넣은 빌드일 때가 많아서, 묻던 것을 묻지 않고 하면 그 빌드가 사라진다.
    ///
    /// **실행 중인 앱은 건너뛴다.** 쓰는 중에 바꿔치면 저장하지 않은 것이 날아간다. 다음
    /// 확인 때 다시 본다.
    static func candidates(
        in catalog: [AppDTO],
        state: (AppDTO) -> InstallState,
        isRunning: (String) -> Bool
    ) -> [AppDTO] {
        catalog.filter { app in
            state(app) == .updateAvailable && !isRunning(app.bundleID)
        }
    }

    /// 실행 중이라 건너뛴 앱 가운데 종료하고 업데이트할지 물어볼 것들 (ADR-0074).
    ///
    /// 자동으로 받을 앱과 기준이 같고 실행 중이라는 것만 다르다. 이 버전을 이미 물어봤으면
    /// 빼고, 그 앱은 목록의 "업데이트" 버튼으로 남는다.
    static func runningCandidates(
        in catalog: [AppDTO],
        state: (AppDTO) -> InstallState,
        isRunning: (String) -> Bool,
        alreadyAsked: [String: String]
    ) -> [AppDTO] {
        catalog.filter { app in
            guard state(app) == .updateAvailable, isRunning(app.bundleID),
                  let version = app.latestReleasedVersion
            else { return false }
            return alreadyAsked[app.bundleID] != version.id.uuidString
        }
    }

    /// 그 번들 ID 의 앱이 지금 떠 있는가.
    @MainActor
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

extension AutoUpdate {
    /// 앱에 정상 종료를 요청하고 끝날 때까지 기다린다. 끝나면 true.
    ///
    /// **강제로 종료하지 않는다.** `terminate()` 는 앱에 종료를 요청할 뿐이라, 저장하지
    /// 않은 작업이 있으면 앱이 묻는다. 사람이 거기서 취소하거나 앱이 응답하지 않으면 시간이
    /// 다 될 때까지 기다리고 그 앱은 건너뛴다. 업데이트가 늦는 편이 작업을 날리는 것보다
    /// 낫다 (설계 문서 5.5 교체 절차).
    @MainActor
    static func quit(bundleID: String, timeout: Duration = .seconds(30)) async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !isRunning(bundleID: bundleID) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return !isRunning(bundleID: bundleID)
    }
}
