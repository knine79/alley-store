import Foundation

/// 스토어 앱이 꺼져 있어도 업데이트를 확인하는 LaunchAgent (이슈 #74, ADR-0080).
///
/// 스토어 앱 번들 안의 `Contents/Library/LaunchAgents/` 에 이 plist 를 두고, 앱이
/// `SMAppService.agent(plistName:)` 로 등록한다. launchd 가 주기마다 **같은 실행 파일**을
/// `argument` 를 붙여 띄우고, 그 실행은 창 없이 확인과 알림만 하고 끝난다.
///
/// plist 를 쓰는 곳이 둘이다. `scripts/build-store-app.sh` 가 베이스 번들에, 서버의
/// `StoreAppBundleRewriter` 가 조직의 번들에 쓴다. 서버 쪽이 조직마다 번들 ID 와 실행 파일
/// 이름을 바꾸므로 원본을 그대로 옮길 수 없다. 두 벌이 같은 값을 내는지는 시험이 본다.
public enum StoreAppUpdateCheck {
    /// 번들 안의 파일 이름. 앱이 등록할 때 이 이름으로 찾는다.
    public static let plistName = "update-check.plist"

    /// 이것을 붙여 띄우면 창을 열지 않고 확인만 한다.
    public static let argument = "--check-updates"

    /// 확인 주기(초). 사내 앱은 하루에 몇 번 올라온다. 더 자주 물어도 얻을 것이 없고,
    /// 맥마다 요청이 나간다. 잠자는 동안 놓친 차례는 깨어날 때 한 번으로 묶인다.
    public static let interval = 4 * 60 * 60

    /// launchd 라벨. 사용자 계정 안에서 겹치면 안 되므로 번들 ID 에 붙인다.
    public static func label(bundleID: String) -> String {
        "\(bundleID).update-check"
    }

    /// 번들 안 `Contents/Library/LaunchAgents/` 에서의 경로.
    public static let bundlePath = "Contents/Library/LaunchAgents/\(plistName)"

    public static func launchAgentPlist(bundleID: String, executable: String) -> String {
        let program = "Contents/MacOS/\(escaped(executable))"
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(escaped(label(bundleID: bundleID)))</string>
                <key>BundleProgram</key>
                <string>\(program)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(program)</string>
                    <string>\(argument)</string>
                </array>
                <key>StartInterval</key>
                <integer>\(interval)</integer>
                <key>ProcessType</key>
                <string>Background</string>
                <key>AssociatedBundleIdentifiers</key>
                <array>
                    <string>\(escaped(bundleID))</string>
                </array>
            </dict>
            </plist>

            """
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
