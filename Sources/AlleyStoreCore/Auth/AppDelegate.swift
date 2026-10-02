import AlleyShared
import AppKit
import os

/// 커스텀 스킴 URL 을 Apple Event 로 받는다. 로그인 콜백(ADR-0068)과 앱 공유
/// 링크(ADR-0072)가 이리로 온다.
///
/// **SwiftUI 의 `onOpenURL` 을 쓰지 않는다.** `WindowGroup` 은 URL 이 들어오면 그것을
/// 받을 창을 고르는데, 고르지 못하면 새 창을 하나 더 띄운다. 이 앱은 창이 하나뿐이어야
/// 한다(새 창 메뉴도 뺐다). 처리기를 직접 걸면 창과 상관없이 받는다.
///
/// **두 번 건다.** 앱을 띄운 URL 은 `applicationWillFinishLaunching` 과
/// `applicationDidFinishLaunching` 사이에 온다. 공유 링크는 앱이 꺼져 있을 때 누르는
/// 경우가 많아서 그것을 받아야 한다. 그런데 같은 이벤트에 AppKit 도 처리기를 걸고,
/// 나중에 건 것이 이긴다. 그래서 시작 직후에 한 번 더 건다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 사용자 맥에서 "링크를 눌렀는데 안 열린다" 를 볼 때
    /// `log stream --predicate 'category == "app-link"'` 로 이것만 걸러낸다.
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "alley-store",
        category: "app-link"
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: raw)
        else { return }
        route(url, via: "apple-event")
    }

    /// 위 처리기를 거치지 않고 AppKit 이 URL 을 받았을 때 여기로 넘긴다.
    ///
    /// 앱이 꺼진 채 링크를 눌렀을 때 위 처리기에 아무것도 오지 않은 적이 스무여 번 중
    /// 두 번 있었다. 그 URL 이 이리로 오는지는 확인하지 못했다. 같은 링크가 두 길로 와도
    /// 마지막 것만 남기므로 해가 없다 (`AppLinkInbox`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { route(url, via: "delegate") }
    }

    private func route(_ url: URL, via path: String) {
        if WebSignIn.shared.handle(url: url) { return }
        if let appID = AppLink.appID(from: url) {
            Self.log.notice("공유 링크를 받았습니다 [앱: \(appID.uuidString, privacy: .public), 경로: \(path, privacy: .public)]")
            AppLinkInbox.shared.receive(appID)
            Task { await Self.showWindowIfNone() }
        } else {
            Self.log.notice("알 수 없는 주소를 버립니다 [호스트: \(url.host ?? "", privacy: .public)]")
        }
    }

    /// 링크를 받았는데 보여줄 창이 없으면 창을 연다.
    ///
    /// 두 경우에 창이 없다. 창을 닫아둔 채 링크를 누르면 앱은 떠 있어도 창이 없다. 앱이
    /// 꺼진 채 링크를 누르면 SwiftUI 가 첫 창을 만들지 않을 때가 있다. 앱을 띄운 URL 을
    /// 이 처리기가 가져가서 SwiftUI 가 받지 못하기 때문으로 보인다. 어느 쪽이든 사람은
    /// 링크를 눌렀는데 아무 일도 없는 것으로 본다.
    ///
    /// **자기 번들을 한 번 더 연다.** 떠 있는 앱을 다시 열면 Dock 아이콘을 누른 것과 같은
    /// 재실행 이벤트가 오고, SwiftUI 는 보이는 창이 없을 때 창을 하나 만든다. 창이 있으면
    /// 아무것도 하지 않으므로 창이 늘지 않는다. SwiftUI 창을 AppKit 에서 직접 여는 공개된
    /// 길이 없다. `newWindowForTab:` 는 받지 않았다.
    ///
    /// **조금 기다렸다가 본다.** 앱이 꺼진 채 링크를 누르면 이 처리기가 첫 창보다 먼저
    /// 불린다. 그때 바로 다시 열면 SwiftUI 가 만들 첫 창과 겹쳐 창이 둘이 될 수 있다.
    private static func showWindowIfNone() async {
        try? await Task.sleep(for: .seconds(1))
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        log.notice("보이는 창이 없어 새로 엽니다")
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } catch {
            log.error("창을 열지 못했습니다 [\(error.localizedDescription, privacy: .public)]")
        }
    }
}
