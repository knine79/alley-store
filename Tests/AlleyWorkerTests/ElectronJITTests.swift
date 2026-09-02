import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

/// Electron 앱을 JIT 권한 없이 서명하면 공증은 통과하고 실행만 안 된다.
///
/// 그 실패는 사용자의 맥에서야 드러나므로 서명 전에 잡는다. 이 검사가 Electron
/// **하나만** 아는 것은 알고 한 선택이다 (ADR-0020).
@Suite("Electron JIT 검사")
struct ElectronJITTests {
    private var pipeline: SigningPipeline {
        SigningPipeline(
            config: WorkerConfig(
                serverURL: URL(string: "https://store.example.com")!,
                token: "alleyw_test",
                name: "테스트 워커",
                signingIdentity: "Developer ID Application: Example (TEAMID)",
                notaryProfile: "alley",
                workDirectory: FileManager.default.temporaryDirectory,
                pollTimeout: 25,
                sparklePrivateKey: nil
            )
        )
    }

    /// Electron 앱의 생김새. 프레임워크가 이 자리에 있으면 그 앱은 V8 을 띄운다.
    private func makeElectronApp(_ fixture: borrowing BundleFixture) throws -> AppBundle {
        let app = try fixture.makeDirectory("도구.app")
        _ = try fixture.makeDirectory(
            "도구.app/Contents/Frameworks/Electron Framework.framework"
        )
        return AppBundle(url: app)
    }

    @Test("Electron 을 품었는지 알아본다")
    func detectsElectron() throws {
        let fixture = try BundleFixture()
        #expect(try makeElectronApp(fixture).containsElectronFramework)

        let plain = try fixture.makeDirectory("보통.app")
        #expect(!AppBundle(url: plain).containsElectronFramework)
    }

    @Test("JIT 권한이 없으면 서명 전에 막는다")
    func blocksWithoutJIT() throws {
        let fixture = try BundleFixture()
        let bundle = try makeElectronApp(fixture)

        #expect(throws: SigningPipeline.PipelineError.self) {
            try pipeline.requireJITForElectron(bundle: bundle, declaredKeys: [])
        }
    }

    @Test("오류에 무엇을 넣어야 하는지 적는다")
    func errorNamesTheKey() throws {
        let fixture = try BundleFixture()
        let bundle = try makeElectronApp(fixture)

        do {
            try pipeline.requireJITForElectron(bundle: bundle, declaredKeys: [])
            Issue.record("막았어야 합니다.")
        } catch {
            // "권한이 필요합니다" 로 끝나면 읽은 사람이 다음에 무엇을 할지 모른다.
            let message = String(describing: error)
            #expect(message.contains(EntitlementsGuidance.jitKey))
            #expect(message.contains("--entitlements"))
        }
    }

    @Test("JIT 권한이 있으면 통과시킨다")
    func passesWithJIT() throws {
        let fixture = try BundleFixture()
        let bundle = try makeElectronApp(fixture)

        try pipeline.requireJITForElectron(
            bundle: bundle,
            declaredKeys: [EntitlementsGuidance.jitKey]
        )
    }

    @Test("Electron 이 아닌 앱은 권한이 없어도 통과시킨다")
    func ignoresNonElectron() throws {
        // 네이티브 맥 앱은 대부분 정말로 entitlements 가 필요 없다.
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("보통.app")

        try pipeline.requireJITForElectron(bundle: AppBundle(url: app), declaredKeys: [])
    }
}
