import Foundation
import Testing

@testable import AlleyWorkerCore

/// 번들이 이미 서명·공증됐는지 워커가 스스로 판정한다.
///
/// 사람에게 묻지 않는 이유는 `SignatureInspection` 의 주석에 있다 (ADR-0035).
@Suite("서명 상태 판정")
struct SignatureInspectionTests {
    // MARK: - codesign 출력에서 Team ID 뽑기

    @Test("TeamIdentifier 줄에서 읽는다")
    func readsTeamIdentifier() {
        let output = """
            Executable=/tmp/Example.app/Contents/MacOS/Example
            Identifier=com.example.app
            Authority=Developer ID Application: Example Inc. (ABCDE12345)
            TeamIdentifier=ABCDE12345
            """
        #expect(SignatureInspection.teamID(fromCodesignOutput: output) == "ABCDE12345")
    }

    /// ad-hoc 서명은 `TeamIdentifier=not set` 으로 나온다. 그것을 팀 이름으로
    /// 읽으면 "not set 팀이 서명했다" 는 엉뚱한 메시지가 나간다.
    @Test("not set 은 팀이 없는 것으로 본다")
    func treatsNotSetAsMissing() {
        #expect(SignatureInspection.teamID(fromCodesignOutput: "TeamIdentifier=not set") == nil)
    }

    @Test("줄이 없으면 nil")
    func returnsNilWhenAbsent() {
        #expect(SignatureInspection.teamID(fromCodesignOutput: "Identifier=com.example.app") == nil)
    }

    // MARK: - identity 이름에서 Team ID 뽑기

    @Test("identity 끝 괄호에서 읽는다")
    func readsTeamIDFromIdentity() {
        let identity = "Developer ID Application: Example Inc. (ABCDE12345)"
        #expect(SignatureInspection.teamID(fromSigningIdentity: identity) == "ABCDE12345")
    }

    /// 회사 이름 자체에 괄호가 들어가는 일이 있다. 마지막 괄호만 보고, 그 안이
    /// Team ID 모양(영숫자 10자)일 때만 받아들인다.
    @Test("이름 안의 괄호를 팀으로 잘못 집지 않는다")
    func ignoresParenthesesInName() {
        let identity = "Developer ID Application: Example (Korea) Inc. (ABCDE12345)"
        #expect(SignatureInspection.teamID(fromSigningIdentity: identity) == "ABCDE12345")

        // 괄호는 있는데 Team ID 모양이 아니면 못 읽은 것으로 친다.
        let noTeam = "Developer ID Application: Example (Korea) Inc."
        #expect(SignatureInspection.teamID(fromSigningIdentity: noTeam) == nil)
    }

    @Test("괄호가 없으면 nil")
    func returnsNilWithoutParentheses() {
        #expect(SignatureInspection.teamID(fromSigningIdentity: "Apple Development") == nil)
    }

    // MARK: - 실제 판정

    /// **애매하면 서명하는 쪽으로 기운다.** 서명이 없는 것을 확인하는 것이
    /// 판정의 첫 관문이다.
    @Test("서명 없는 번들은 서명해야 한다고 본다")
    func unsignedNeedsSigning() async throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-unsigned-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let inspection = await SignatureInspection.inspect(bundle: bundle, expectedTeamID: nil)
        #expect(!inspection.isAlreadyDone)
    }
}
