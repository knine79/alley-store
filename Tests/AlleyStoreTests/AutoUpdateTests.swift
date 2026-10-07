import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

/// 묻지 않고 업데이트할 앱 고르기 (ADR-0073).
@Suite("자동 업데이트")
struct AutoUpdateTests {
    private func app(_ bundleID: String, versionID: UUID = UUID()) -> AppDTO {
        let id = UUID()
        return AppDTO(
            id: id, bundleID: bundleID, name: bundleID, ownerID: UUID(),
            latestReleasedVersion: VersionDTO(
                id: versionID, appID: id, shortVersion: "1.0", buildNumber: 1,
                state: .released, createdAt: Date()
            ),
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
        let catalog = states.keys.sorted().map { app($0) }
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

    /// 실행 중이라 건너뛴 앱만 묻는다. 실행 중이 아니면 묻지 않고 받는다.
    @Test("실행 중이고 업데이트가 있는 앱만 묻는다")
    func asksOnlyRunningUpdates() {
        let catalog = [app("running"), app("idle"), app("running-latest")]
        let asked = AutoUpdate.runningCandidates(
            in: catalog,
            state: { $0.bundleID == "running-latest" ? .upToDate : .updateAvailable },
            isRunning: { $0.hasPrefix("running") },
            alreadyAsked: [:]
        )
        #expect(asked.map(\.bundleID) == ["running"])
    }

    /// "나중에" 를 누른 버전은 30분마다 다시 묻지 않는다. 새 버전이 나오면 다시 묻는다.
    @Test("물어본 버전은 다시 묻지 않고, 새 버전은 묻는다")
    func asksEachVersionOnce() throws {
        let store = try #require(UserDefaults(suiteName: "auto-update-tests-\(UUID().uuidString)"))
        let first = app("running")
        UpdatePreferences.rememberAsked([first], store)

        func candidates(_ catalog: [AppDTO]) -> [AppDTO] {
            AutoUpdate.runningCandidates(
                in: catalog,
                state: { _ in .updateAvailable },
                isRunning: { _ in true },
                alreadyAsked: UpdatePreferences.askedRunning(store)
            )
        }
        #expect(candidates([first]).isEmpty)
        let next = app("running", versionID: UUID())
        #expect(candidates([next]).map(\.bundleID) == ["running"])
    }
}
