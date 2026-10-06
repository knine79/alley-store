import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

/// 묻지 않고 업데이트할 앱 고르기 (ADR-0073).
@Suite("자동 업데이트")
struct AutoUpdateTests {
    private func app(_ bundleID: String) -> AppDTO {
        AppDTO(
            id: UUID(), bundleID: bundleID, name: bundleID, ownerID: UUID(),
            createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("업데이트 있음인 앱만 고른다")
    func onlyUpdateAvailable() {
        let states: [String: InstallState] = [
            "update": .updateAvailable,
            // 사람이 누를 때도 덮어쓸지 묻는 경우들이다. 묻지 않고 하면 직접 넣은 빌드가 사라진다.
            "ahead": .ahead,
            "unknown": .unknown,
            "latest": .upToDate,
            "none": .notInstalled,
        ]
        let catalog = states.keys.sorted().map(app)
        let picked = AutoUpdate.candidates(
            in: catalog,
            state: { states[$0.bundleID]! },
            isRunning: { _ in false }
        )
        #expect(picked.map(\.bundleID) == ["update"])
    }

    /// 쓰는 중에 바꿔치면 저장하지 않은 것이 날아간다.
    @Test("실행 중인 앱은 건너뛴다")
    func skipsRunningApps() {
        let catalog = [app("running"), app("idle")]
        let picked = AutoUpdate.candidates(
            in: catalog,
            state: { _ in .updateAvailable },
            isRunning: { $0 == "running" }
        )
        #expect(picked.map(\.bundleID) == ["idle"])
    }

    @Test("건드린 적이 없으면 앱 자동 업데이트는 켜져 있다")
    func defaultIsOn() throws {
        let store = try #require(UserDefaults(suiteName: "auto-update-tests-\(UUID().uuidString)"))
        #expect(UpdatePreferences.autoUpdatesApps(store))
        store.set(false, forKey: UpdatePreferences.appsKey)
        #expect(!UpdatePreferences.autoUpdatesApps(store))
    }
}
