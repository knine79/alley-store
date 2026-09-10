import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

/// 번들 ID 를 모른 채 올라온 잡.
///
/// dmg 는 브라우저가 열 수 없어 등록 시점에 번들 ID 를 알 수 없다. 그때는 대조할
/// 것이 없으므로 **조직 정책 검사가 그 자리를 대신한다.** 이것이 없으면 아무 앱이나
/// 올려서 조직 Developer ID 로 서명받을 수 있다 (ADR-0034).
@Suite("확정 전 번들 ID")
struct PendingBundleIDTests {
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

    private func makeApp(
        _ fixture: borrowing BundleFixture,
        identifier: String?
    ) throws -> AppBundle {
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeInfoPlist(
            "도구.app/Contents/Info.plist", executable: "도구", identifier: identifier
        )
        return AppBundle(url: app)
    }

    private func job(
        pending: Bool,
        registered: String = "alley-pending.0000",
        prefix: String? = "com.example",
        enforce: Bool = true
    ) -> SigningJobDTO {
        SigningJobDTO(
            id: UUID(),
            versionID: UUID(),
            appBundleID: registered,
            appBundleIDPending: pending ? true : nil,
            requiredBundleIDPrefix: pending ? prefix : nil,
            enforceBundleIDPrefix: pending ? enforce : nil,
            artifactDownloadURL: "https://storage.example.com/in",
            resultUploadURL: "https://storage.example.com/out",
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    @Test("정책에 맞으면 통과시킨다")
    func acceptsMatchingPrefix() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.도구")

        try pipeline.requireAcceptableBundleIdentifier(of: bundle, for: job(pending: true))
    }

    /// **이 검사가 이 기능의 문턱이다.** 사람이 아무 값도 적지 않으므로, 번들이
    /// 말하는 ID 를 그대로 받아들이게 된다. 여기서 막지 않으면 남의 앱이 조직
    /// 이름으로 서명된다.
    @Test("정책에 맞지 않으면 서명 전에 막는다")
    func rejectsForeignBundleID() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.apple.Safari")

        do {
            try pipeline.requireAcceptableBundleIdentifier(of: bundle, for: job(pending: true))
            Issue.record("막았어야 합니다.")
        } catch let error as SigningPipeline.PipelineError {
            #expect(error.failureCode == .bundleIdentifierMismatch)
            let message = String(describing: error)
            #expect(message.contains("com.apple.Safari"))
            #expect(message.contains("com.example"))
        }
    }

    /// 프리픽스와 글자가 겹치기만 하는 것은 통과시키지 않는다.
    /// `com.example` 정책에 `com.examplefoo.app` 이 통과하면 정책이 없는 것과 같다.
    @Test("접두어가 글자만 겹치는 것은 막는다")
    func rejectsPrefixLookalike() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.examplefoo.도구")

        #expect(throws: SigningPipeline.PipelineError.self) {
            try pipeline.requireAcceptableBundleIdentifier(of: bundle, for: job(pending: true))
        }
    }

    @Test("정책이 권장일 뿐이면 막지 않는다")
    func allowsWhenNotEnforced() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.other.도구")

        try pipeline.requireAcceptableBundleIdentifier(
            of: bundle, for: job(pending: true, enforce: false)
        )
    }

    @Test("정책이 없으면 아무 ID 나 통과한다")
    func allowsWhenNoPolicy() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.other.도구")

        try pipeline.requireAcceptableBundleIdentifier(
            of: bundle, for: job(pending: true, prefix: nil)
        )
    }

    @Test("번들 ID 가 없으면 막는다")
    func rejectsMissingBundleID() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: nil)

        #expect(throws: SigningPipeline.PipelineError.self) {
            try pipeline.requireAcceptableBundleIdentifier(of: bundle, for: job(pending: true))
        }
    }

    /// 확정된 앱은 예전처럼 대조한다. 정책 검사로 바뀌지 않는다.
    @Test("확정된 앱은 등록값과 대조한다")
    func confirmedAppStillCompares() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.다른앱")

        do {
            try pipeline.requireAcceptableBundleIdentifier(
                of: bundle,
                for: job(pending: false, registered: "com.example.도구")
            )
            Issue.record("막았어야 합니다.")
        } catch let error as SigningPipeline.PipelineError {
            #expect(error.failureCode == .bundleIdentifierMismatch)
            // 정책은 맞지만(둘 다 com.example.) 등록값과 다르다.
            #expect(String(describing: error).contains("com.example.도구"))
        }
    }

    /// 이 필드를 모르는 예전 서버가 보낸 지시서다. 늘 대조하던 대로 동작해야 한다.
    @Test("pending 을 안 보낸 지시서는 대조로 다룬다")
    func treatsMissingFlagAsConfirmed() throws {
        let fixture = try BundleFixture()
        let bundle = try makeApp(fixture, identifier: "com.example.도구")

        let old = SigningJobDTO(
            id: UUID(),
            versionID: UUID(),
            appBundleID: "com.example.도구",
            artifactDownloadURL: "https://storage.example.com/in",
            resultUploadURL: "https://storage.example.com/out",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try pipeline.requireAcceptableBundleIdentifier(of: bundle, for: old)
    }
}
