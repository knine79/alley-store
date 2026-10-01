import AppKit

/// 로그인 콜백 URL 을 Apple Event 로 받는다 (ADR-0068).
///
/// **SwiftUI 의 `onOpenURL` 을 쓰지 않는다.** `WindowGroup` 은 URL 이 들어오면 그것을
/// 받을 창을 고르는데, 고르지 못하면 새 창을 하나 더 띄운다. 이 앱은 창이 하나뿐이어야
/// 한다(새 창 메뉴도 뺐다). 처리기를 직접 걸면 창과 상관없이 받는다.
///
/// **`applicationDidFinishLaunching` 에서 건다.** 같은 이벤트에 AppKit 이 먼저 처리기를
/// 걸어두는데, 나중에 건 것이 이긴다. 실행 전에 들어온 URL 은 받지 못하지만, 로그인
/// 콜백은 앱이 떠서 기다리고 있을 때만 뜻이 있다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        MainActor.assumeIsolated {
            _ = WebSignIn.shared.handle(url: url)
        }
    }
}
