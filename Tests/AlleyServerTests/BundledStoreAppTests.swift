import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 서버 이미지에 함께 들어 있는 스토어 앱 번들 (ADR-0048).
///
/// **이것이 있어야 스토어를 세우자마자 스토어 앱을 내보낼 수 있다.** 예전에는 제품
/// 릴리스에서 zip 을 받아 관리 화면에 올려야 빌드 버튼이 켜졌다. 그 한 단계가 새
/// 조직마다 걸렸고, 제품을 올릴 때마다 다시 걸렸다.
@Suite("서버에 딸려 오는 스토어 앱 번들")
struct BundledStoreAppTests {
    /// 이미지 안의 자리에 번들을 놓아둔다. 실제 배포에서는 CI 가 넣는다.
    ///
    /// **레포 디렉터리를 건드리지 않는다.** 예전에는 실제 자리에 써 넣고 지웠는데,
    /// 그러면 그 자리에 파일을 두고 개발할 수 없었다. `withMigratedApp` 이 잡아둔
    /// 임시 자리를 쓴다.
    private func withBundled(
        in app: Application, _ body: () async throws -> Void
    ) async throws {
        try await withBundledStoreApp(body)
    }

    private func settings(on app: Application) async throws -> StoreAppSettings {
        let settings = try await StoreAppSettings.loadOrSeed(
            on: app.db, config: app.alleyConfig, logger: app.logger
        )
        settings.bundleID = "com.example.alley.store"
        settings.appName = "우리 스토어"
        try await settings.save(on: app.db)
        return settings
    }

    @Test("아무것도 안 올려도 이미지 안의 것으로 빌드한다")
    func buildsFromTheBundledCopy() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let settings = try await settings(on: app)
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            try await withBundled(in: app) {
                let result = try await StoreAppBuildService.build(
                    settings: settings,
                    icon: nil,
                    serverURL: "https://store.example.com",
                    by: admin,
                    storage: storage,
                    on: app.db,
                    directory: app.directory,
                    logger: app.logger
                )

                // **버전은 서버 버전이다.** 둘이 같은 커밋에서 나오므로 어긋날 수
                // 없다. 사람이 적던 칸이 사라지는 것이 이 변경의 요점이다.
                #expect(result.shortVersion == AlleyVersion.current)
                #expect(result.buildNumber == 1)
            }
        }
    }

    /// 올린 것이 있으면 그것이 이긴다. 특정 번들을 콕 집어 내보내야 할 때가 있다.
    @Test("올린 것이 이미지 안의 것보다 우선한다")
    func uploadedWins() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let settings = try await settings(on: app)
            let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)

            try await withBundled(in: app) {
                try await StoreAppBuildService.acceptBaseBundle(
                    version: "9.9.9",
                    data: StoreAppBundleRewriterTests.baseZip(),
                    settings: settings,
                    by: admin,
                    storage: storage,
                    on: app.db,
                    logger: app.logger
                )

                let chosen = try #require(
                    StoreAppBuildService.baseBundle(settings: settings, in: app.directory)
                )
                #expect(chosen.version == "9.9.9")
                #expect(chosen.isUploaded)
            }
        }
    }

    /// 번들이 없는 이미지로 돌 때. 로컬에서 `docker build` 를 그냥 돌렸거나 macOS
    /// 잡이 실패한 릴리스가 그렇다. 그때는 예전처럼 사람이 올리는 길로 굴러간다.
    @Test("이미지에 없고 올린 것도 없으면 빌드할 것이 없다")
    func nothingToBuild() async throws {
        try await withMigratedApp { app in
            let settings = try await settings(on: app)
            #expect(StoreAppBuildService.baseBundle(settings: settings, in: app.directory) == nil)
        }
    }
}
