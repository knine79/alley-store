import AlleyShared
import AppKit
import Foundation
import OSLog
import ServiceManagement
import UserNotifications

/// 스토어 앱이 꺼져 있어도 설치한 앱의 업데이트를 확인해 알림으로 알린다 (이슈 #74, ADR-0080).
///
/// 스토어 앱을 자주 열지 않는 사람은 새 버전이 나와도 모른 채 옛 버전을 쓴다. 번들 안의
/// LaunchAgent 가 4시간마다 같은 실행 파일을 `--check-updates` 로 띄우고, 그 실행은 창을
/// 열지 않고 이 타입의 `runAndExit()` 만 돌고 끝난다 (`main.swift`).
///
/// **알리기만 한다.** 받는 것은 사람이 알림을 눌러 스토어 앱을 연 뒤, 열 때 하던 그대로
/// 한다. 창 없는 프로세스가 실행 중인 앱을 건드리면 사람이 모르는 사이에 앱이 바뀐다.
public enum BackgroundUpdateCheck {
    /// `log stream --predicate 'category == "update-check"'` 로 이것만 본다.
    static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "alley-store",
        category: "update-check"
    )

    /// 알림 센터에서 이 알림을 가리키는 이름. 새 알림이 앞의 것을 갈아끼운다. 업데이트
    /// 수가 바뀔 때마다 알림이 쌓이면 무엇이 지금 것인지 알 수 없다.
    static let notificationID = "update-check"

    /// 창 없이 띄워졌는가.
    public static var isRequested: Bool {
        CommandLine.arguments.contains(StoreAppUpdateCheck.argument)
    }

    /// 확인하고 프로세스를 끝낸다. 어떤 실패도 사람에게 보이지 않는다. 다음 차례에 다시 본다.
    public static func runAndExit() -> Never {
        Task {
            await run()
            exit(0)
        }
        dispatchMain()
    }

    static func run() async {
        guard UpdatePreferences.checksInBackground() else {
            log.notice("백그라운드 확인이 꺼져 있어 건너뜁니다")
            return
        }
        // 스토어 앱이 떠 있으면 그쪽이 30분마다 확인하고 화면에 보여준다. 같은 것을 알림으로
        // 또 띄울 이유가 없다.
        if isStoreAppRunning() {
            log.notice("스토어 앱이 실행 중이라 건너뜁니다")
            return
        }
        let credentials = Credentials()
        guard let server = BuiltInServer.url ?? credentials.serverURL,
              let token = credentials.token(for: server)
        else {
            log.notice("로그인하지 않아 건너뜁니다")
            return
        }

        var client = StoreClient(server: server)
        client.token = token
        let apps: [AppDTO]
        do {
            apps = try await client.apps()
        } catch StoreClient.ClientError.unauthorized {
            // 토큰이 만료됐다(ADR-0069). 여기서 지우거나 갱신하지 않는다. 스토어 앱을 열면
            // 그쪽이 로그인 화면으로 보낸다. 창 없는 프로세스가 로그아웃시키면 사람은 이유를
            // 모른다.
            log.notice("토큰이 만료돼 건너뜁니다")
            return
        } catch {
            log.notice("서버에 묻지 못했습니다 [\(error.localizedDescription, privacy: .public)]")
            return
        }

        let pending = UpdateNotice.pending(
            in: apps,
            installed: InstalledApps.scan(),
            isSelf: { app in
                if let flag = app.isStoreApp { return flag }
                return app.bundleID == Bundle.main.bundleIdentifier
            }
        )
        let (notice, remember) = UpdateNotice.plan(
            pending: pending,
            notified: UpdatePreferences.notifiedUpdates()
        )
        log.notice("업데이트 \(pending.count)개, 새로 알릴 것 \(notice == nil ? "없음" : "있음", privacy: .public)")

        guard let notice else {
            UpdatePreferences.rememberNotified(remember)
            return
        }
        // 보내지 못했으면 기억하지 않는다. 기억하면 다음 차례에 "이미 알렸다" 로 넘어간다.
        if await post(notice) {
            UpdatePreferences.rememberNotified(remember)
        }
    }

    private static func isStoreAppRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
    }

    private static func post(_ notice: UpdateNotice) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            // 권한은 스토어 앱이 켜질 때 묻는다. 창 없는 프로세스에서 물으면 사람은 무엇이
            // 묻는지 모른다.
            log.notice("알림 권한이 없어 보내지 않습니다")
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
            return true
        } catch {
            log.error("알림을 보내지 못했습니다 [\(error.localizedDescription, privacy: .public)]")
            return false
        }
    }

    // MARK: - 등록

    /// 설정에 맞게 LaunchAgent 를 등록하거나 내린다. 스토어 앱이 로그인한 뒤와 설정을 바꿀
    /// 때 부른다.
    ///
    /// 켤 때 알림 권한을 묻는다. 처음 한 번만 시스템 창이 뜨고 그 뒤로는 답이 바로 온다.
    @MainActor
    static func sync() async {
        let service = SMAppService.agent(plistName: StoreAppUpdateCheck.plistName)
        if UpdatePreferences.checksInBackground() {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard service.status != .enabled else { return }
            do {
                try service.register()
                log.notice("백그라운드 확인을 등록했습니다 [상태: \(String(describing: service.status), privacy: .public)]")
            } catch {
                // 번들 밖에서 띄웠거나(`swift run`) 서명이 없으면 여기로 온다. 앱을 쓰는 데는
                // 지장이 없으니 기록만 남긴다.
                log.error("백그라운드 확인을 등록하지 못했습니다 [\(error.localizedDescription, privacy: .public)]")
            }
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            do {
                try await service.unregister()
                log.notice("백그라운드 확인을 내렸습니다")
            } catch {
                log.error("백그라운드 확인을 내리지 못했습니다 [\(error.localizedDescription, privacy: .public)]")
            }
        }
    }

    /// 스토어 앱을 열었으면 띄워둔 알림은 낡은 것이다. 열면서 확인을 다시 하니 걷는다.
    static func clearDeliveredNotice() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }
}
