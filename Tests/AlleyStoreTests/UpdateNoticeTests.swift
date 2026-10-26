import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

/// 스토어 앱이 꺼져 있을 때 띄울 업데이트 알림 (이슈 #74).
@Suite("업데이트 알림")
struct UpdateNoticeTests {
    private func app(
        _ name: String, bundleID: String? = nil, version: String = "2.0.0", build: Int = 20,
        versionID: UUID = UUID(), isStoreApp: Bool? = nil
    ) -> AppDTO {
        let id = UUID()
        return AppDTO(
            id: id, bundleID: bundleID ?? "com.example.\(name.lowercased())", name: name,
            ownerID: UUID(),
            latestReleasedVersion: VersionDTO(
                id: versionID, appID: id, shortVersion: version, buildNumber: build,
                state: .released, createdAt: Date()
            ),
            isStoreApp: isStoreApp,
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func installed(_ bundleID: String, build: Int) -> InstalledApp {
        InstalledApp(
            bundleID: bundleID, shortVersion: "1.0", buildNumber: build,
            location: URL(fileURLWithPath: "/Applications/x.app"), bundleVersion: "\(build)"
        )
    }

    @Test("깔린 것보다 새 출시본이 있는 앱만, 스토어 앱 자신은 빼고 이름순으로")
    func picksPendingUpdates() {
        let notes = app("Notes")
        let calendar = app("Calendar")
        let fresh = app("Fresh", build: 5)
        let missing = app("Missing")
        let store = app("Store", isStoreApp: true)
        let pending = UpdateNotice.pending(
            in: [notes, calendar, fresh, missing, store],
            installed: [
                notes.bundleID: installed(notes.bundleID, build: 10),
                calendar.bundleID: installed(calendar.bundleID, build: 10),
                fresh.bundleID: installed(fresh.bundleID, build: 5),
                store.bundleID: installed(store.bundleID, build: 1),
            ],
            isSelf: { $0.isStoreApp == true }
        )
        #expect(pending.map(\.name) == ["Calendar", "Notes"])
    }

    @Test("이미 알린 버전만 남았으면 다시 알리지 않는다")
    func doesNotRepeat() {
        let notes = app("Notes")
        let first = UpdateNotice.plan(pending: [notes], notified: [:])
        #expect(first.notice != nil)

        let again = UpdateNotice.plan(pending: [notes], notified: first.remember)
        #expect(again.notice == nil)
        #expect(again.remember == first.remember)
    }

    @Test("새 버전이 하나라도 생기면 남은 것까지 묶어 알린다")
    func bundlesWithNew() {
        let notes = app("Notes")
        let remembered = UpdateNotice.plan(pending: [notes], notified: [:]).remember
        let calendar = app("Calendar")
        let next = UpdateNotice.plan(pending: [calendar, notes], notified: remembered)
        #expect(next.notice?.title == "업데이트 2개")
        #expect(next.notice?.body == "Calendar, Notes의 새 버전이 나왔습니다. 눌러서 업데이트하세요.")
    }

    @Test("같은 앱에 새 버전이 나오면 다시 알린다")
    func notifiesNewerVersionOfSameApp() {
        let old = app("Notes", versionID: UUID())
        let remembered = UpdateNotice.plan(pending: [old], notified: [:]).remember
        let newer = app("Notes", bundleID: old.bundleID, version: "2.1.0", versionID: UUID())
        #expect(UpdateNotice.plan(pending: [newer], notified: remembered).notice != nil)
    }

    @Test("업데이트한 앱은 기억에서 빠진다")
    func forgetsUpdatedApps() {
        let notes = app("Notes")
        let remembered = UpdateNotice.plan(pending: [notes], notified: [:]).remember
        let after = UpdateNotice.plan(pending: [], notified: remembered)
        #expect(after.notice == nil)
        #expect(after.remember.isEmpty)
    }

    @Test("앱이 하나면 이름과 버전을 적는다")
    func singleNotice() {
        #expect(UpdateNotice.notice(for: [app("Calendar Bar", version: "2.3.0")])
            == UpdateNotice(title: "Calendar Bar 업데이트", body: "2.3.0 이 나왔습니다. 눌러서 업데이트하세요."))
        #expect(UpdateNotice.notice(for: [app("Notes", version: "1.2")])?.body
            == "1.2 가 나왔습니다. 눌러서 업데이트하세요.")
    }

    @Test("넷 이상이면 셋까지 적고 나머지는 수로")
    func longList() {
        let notice = UpdateNotice.notice(for: [
            app("Calendar Bar"), app("Notes Sync"), app("Tiny VPN"), app("Zoomer"),
        ])
        #expect(notice?.title == "업데이트 4개")
        #expect(notice?.body == "Calendar Bar, Notes Sync, Tiny VPN 외 1개의 새 버전이 나왔습니다. 눌러서 업데이트하세요.")
    }

    @Test("백그라운드 확인은 기본으로 켜져 있다")
    func backgroundCheckDefaultsOn() throws {
        let store = try #require(UserDefaults(suiteName: "UpdateNoticeTests-\(UUID().uuidString)"))
        #expect(UpdatePreferences.checksInBackground(store))
        store.set(false, forKey: UpdatePreferences.backgroundKey)
        #expect(!UpdatePreferences.checksInBackground(store))
    }
}
