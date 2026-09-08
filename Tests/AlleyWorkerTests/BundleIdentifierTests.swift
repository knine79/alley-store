import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

/// 올린 번들이 등록된 앱과 같은 앱인지 서명 전에 확인한다.
///
/// 이 검사가 없으면 아무 앱이나 조직의 Developer ID 로 서명되고 공증까지 받는다.
/// 공증 티켓은 회수할 수 없으므로 되돌릴 방법이 없다 (ADR-0029).
@Suite("번들 ID 대조")
struct BundleIdentifierTests {
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

    /// `identifier` 가 nil 이면 `CFBundleIdentifier` 없는 번들이 된다.
    private func makeApp(
        _ fixture: borrowing BundleFixture,
        identifier: String?,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> AppBundle {
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeInfoPlist(
            "도구.app/Contents/Info.plist",
            executable: "도구",
            identifier: identifier,
            format: format
        )
        return AppBundle(url: app)
    }

    @Test("Info.plist 에서 번들 ID 를 읽는다")
    func readsIdentifier() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.도구")

        #expect(bundle.bundleIdentifier == "com.example.도구")
    }

    /// 실제 앱의 Info.plist 는 대부분 바이너리 plist 다. XML 만 읽으면 현장에서 전부
    /// "번들 ID 없음" 이 되어, 이 검사가 모든 업로드를 막는 쪽으로 고장난다.
    @Test("바이너리 plist 도 읽는다")
    func readsBinaryPlist() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.도구", format: .binary)

        #expect(bundle.bundleIdentifier == "com.example.도구")
    }

    @Test("Info.plist 가 없으면 번들 ID 도 없다")
    func missingPlistYieldsNil() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")

        #expect(AppBundle(url: app).bundleIdentifier == nil)
    }

    @Test("같으면 통과시킨다")
    func passesOnMatch() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.도구")

        try pipeline.requireDeclaredBundleIdentifier(
            of: bundle, matches: "com.example.도구"
        )
    }

    @Test("다르면 서명 전에 막는다")
    func blocksOnMismatch() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.다른앱")

        do {
            try pipeline.requireDeclaredBundleIdentifier(
                of: bundle, matches: "com.example.도구"
            )
            Issue.record("막았어야 합니다.")
        } catch let error as SigningPipeline.PipelineError {
            #expect(error.failureCode == .bundleIdentifierMismatch)
            // 어느 쪽이 무엇인지 둘 다 적혀야 한다. 하나만 적으면 올린 사람이
            // 자기 빌드가 틀렸는지 등록이 틀렸는지 알 수 없다.
            let message = String(describing: error)
            #expect(message.contains("com.example.다른앱"))
            #expect(message.contains("com.example.도구"))
        }
    }

    /// 대문자만 다른 경우다. 번들 ID 는 대소문자를 구분하므로 다른 앱이다.
    @Test("대소문자가 다르면 다른 것으로 본다")
    func isCaseSensitive() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.Tool")

        #expect(throws: SigningPipeline.PipelineError.self) {
            try pipeline.requireDeclaredBundleIdentifier(
                of: bundle, matches: "com.example.tool"
            )
        }
    }

    /// 프리픽스가 같아도 통과시키지 않는다. `com.example.tool` 로 등록해두고
    /// `com.example.tool.helper` 를 올리는 것은 다른 앱을 올리는 것이다.
    @Test("프리픽스만 같아도 막는다")
    func rejectsPrefixOnlyMatch() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.tool.helper")

        #expect(throws: SigningPipeline.PipelineError.self) {
            try pipeline.requireDeclaredBundleIdentifier(
                of: bundle, matches: "com.example.tool"
            )
        }
    }

    @Test("번들 ID 가 없으면 막는다")
    func blocksWhenIdentifierAbsent() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: nil)

        do {
            try pipeline.requireDeclaredBundleIdentifier(
                of: bundle, matches: "com.example.도구"
            )
            Issue.record("막았어야 합니다.")
        } catch let error as SigningPipeline.PipelineError {
            #expect(error.failureCode == .bundleIdentifierMismatch)
            #expect(String(describing: error).contains("CFBundleIdentifier"))
        }
    }

    /// 다시 올려도 같은 결과다. 서버가 자동으로 다시 내보내면 안 된다.
    @Test("재시도하지 않는 갈래다")
    func isNotRetriable() {
        #expect(!SigningFailureCode.bundleIdentifierMismatch.isRetriable)
    }
}
