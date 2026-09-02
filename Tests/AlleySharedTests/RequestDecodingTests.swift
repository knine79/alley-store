import Foundation
import Testing

@testable import AlleyShared

/// 기본값이 있는 항목은 JSON 에서도 없어도 된다.
///
/// Swift 가 만들어주는 디코더는 `Bool` 이나 enum 을 필수로 본다. 그러면 초기값을
/// 준 항목까지 요청에 반드시 넣어야 하고, `{"rating": 5}` 처럼 당연해 보이는 요청이
/// 400 으로 떨어진다. 실제로 그렇게 한 번 깨져서 테스트로 못박는다.
@Suite("요청 디코딩")
struct RequestDecodingTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("피드백은 익명 여부를 빼도 된다")
    func feedbackDefaultsToNamed() throws {
        let request = try decode(#"{"rating": 5}"#, as: SubmitFeedbackRequest.self)
        #expect(request.rating == 5)
        #expect(!request.isAnonymous)
    }

    @Test("피드백의 익명 여부를 주면 그대로 읽는다")
    func feedbackReadsAnonymous() throws {
        let request = try decode(
            #"{"body": "느립니다", "isAnonymous": true}"#,
            as: SubmitFeedbackRequest.self
        )
        #expect(request.isAnonymous)
        #expect(request.body == "느립니다")
    }

    @Test("버전 생성은 업로드 종류를 빼면 미서명으로 본다")
    func versionDefaultsToUnsigned() throws {
        let request = try decode(
            #"{"shortVersion": "1.0.0", "buildNumber": 3}"#,
            as: CreateVersionRequest.self
        )
        #expect(request.uploadKind == .unsigned)
        #expect(request.buildNumber == 3)
    }

    @Test("버전 생성에 종류를 주면 그대로 읽는다")
    func versionReadsUploadKind() throws {
        let request = try decode(
            #"{"shortVersion": "1.0.0", "buildNumber": 3, "uploadKind": "signed"}"#,
            as: CreateVersionRequest.self
        )
        #expect(request.uploadKind == .signed)
    }

    @Test("버전 생성에 꼭 필요한 것은 빠지면 실패한다")
    func versionStillRequiresEssentials() {
        // 기본값을 줄 수 없는 항목까지 느슨하게 만들면 빈 버전이 만들어진다.
        #expect(throws: (any Error).self) {
            try decode(#"{"buildNumber": 3}"#, as: CreateVersionRequest.self)
        }
    }

    @Test("버전 생성은 entitlements 를 빼도 된다")
    func versionAllowsMissingEntitlements() throws {
        // 대부분의 앱은 안 보낸다. 필수로 보면 그 앱들이 전부 400 으로 떨어진다.
        let request = try decode(
            #"{"shortVersion": "1.0.0", "buildNumber": 3}"#,
            as: CreateVersionRequest.self
        )
        #expect(request.entitlements == nil)
    }

    @Test("버전 생성에 entitlements 를 주면 그대로 읽는다")
    func versionReadsEntitlements() throws {
        let request = try decode(
            #"{"shortVersion": "1.0.0", "buildNumber": 3, "entitlements": "<plist/>"}"#,
            as: CreateVersionRequest.self
        )
        #expect(request.entitlements == "<plist/>")
    }

    @Test("서명 지시서는 entitlements 가 없어도 읽힌다")
    func signingJobAllowsMissingEntitlements() throws {
        // 이 필드를 모르는 예전 서버가 보낸 지시서도 워커가 그대로 해석해야 한다.
        let job = try decode(
            """
            {"id": "00000000-0000-0000-0000-000000000001",
             "versionID": "00000000-0000-0000-0000-000000000002",
             "appBundleID": "com.example.tool",
             "artifactDownloadURL": "https://storage.example/unsigned.zip",
             "resultUploadURL": "https://storage.example/signed.zip",
             "expiresAt": 0}
            """,
            as: SigningJobDTO.self
        )
        #expect(job.entitlements == nil)
    }

    @Test("알림 대상은 채널을 빼면 Slack 으로 본다")
    func notificationDefaultsToSlack() throws {
        let request = try decode(
            #"{"name": "팀 채널", "endpoint": "https://hooks.slack.com/services/T/B/x"}"#,
            as: CreateNotificationTargetRequest.self
        )
        #expect(request.kind == .slack)
    }
}
