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

    /// 그 번들 ID 의 앱이 지금 떠 있는가.
    @MainActor
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
