import AlleyProcess
import Foundation

/// 번들이 이미 서명·공증돼 있는지 본다.
///
/// 사람에게 "이거 서명하셨나요" 를 묻지 않으려고 만들었다. 물어보면 틀리게 답할 수
/// 있고, 틀린 답을 아무도 검사하지 않으면 서명 안 된 앱이 그대로 배포된다
/// (ADR-0035).
public enum SignatureInspection: Sendable {
    /// 우리 팀 Developer ID 로 서명됐고 공증 티켓까지 박혀 있다. 할 일이 없다.
    case alreadyDone
    /// 서명해야 한다. 미서명이거나, ad-hoc 이거나, 남의 팀 것이거나, 공증이 없다.
    case needsSigning(reason: String)

    public var isAlreadyDone: Bool {
        if case .alreadyDone = self { return true }
        return false
    }

    /// 왜 그렇게 판정했는지. 잡 로그에 남긴다.
    public var reason: String {
        switch self {
        case .alreadyDone:
            return "이미 우리 Developer ID 로 서명·공증된 번들입니다. 서명을 건너뜁니다."
        case .needsSigning(let reason):
            return reason
        }
    }

    /// 번들을 들여다보고 판정한다.
    ///
    /// 셋을 모두 만족해야 "다 됐다" 로 본다.
    ///
    /// 1. Developer ID 로 서명돼 있다 (ad-hoc 도 미서명도 아니다)
    /// 2. **우리 팀** 것이다. 남의 팀이 서명한 것은 우리 이름으로 다시 서명해야 한다
    /// 3. 공증 티켓이 박혀 있다
    ///
    /// 하나라도 아니면 서명한다. 애매하면 서명하는 쪽이 안전하다. 이미 된 것을 다시
    /// 하면 시간만 쓰지만, 안 된 것을 됐다고 넘기면 사용자 맥에서 안 열린다.
    public static func inspect(
        bundle: URL,
        expectedTeamID: String?
    ) async -> SignatureInspection {
        let info = await Shell.runDetached(
            "/usr/bin/codesign", ["-dv", "--verbose=2", bundle.path], timeout: 120
        )
        // `codesign -dv` 는 서명이 없으면 실패한다. 그 자체가 답이다.
        guard info.succeeded else {
            return .needsSigning(reason: "서명이 없는 번들입니다.")
        }

        let output = info.combinedOutput
        if output.contains("Signature=adhoc") {
            return .needsSigning(reason: "ad-hoc 서명된 번들입니다. 다른 맥에서 열리지 않습니다.")
        }
        guard output.contains("Authority=Developer ID Application:") else {
            return .needsSigning(
                reason: "Developer ID 로 서명된 번들이 아닙니다. 배포용 서명이 필요합니다."
            )
        }

        // 남의 팀이 서명한 것은 우리 이름으로 다시 서명한다. 그대로 내보내면 이
        // 스토어가 남의 서명을 중계하는 셈이 된다.
        if let expected = expectedTeamID,
           let found = teamID(fromCodesignOutput: output),
           found != expected {
            return .needsSigning(
                reason: "다른 팀(\(found))이 서명한 번들입니다. 이 스토어의 이름으로 다시 서명합니다."
            )
        }

        // 공증 티켓이 박혀 있어야 인터넷 없이도 열린다. 서명만 있고 티켓이 없으면
        // 받은 사람의 맥이 Apple 에 물어봐야 하고, 그 조회가 실패하면 안 열린다.
        let staple = await Shell.runDetached(
            "/usr/bin/xcrun", ["stapler", "validate", bundle.path], timeout: 120
        )
        guard staple.succeeded else {
            return .needsSigning(reason: "공증 티켓이 없습니다. 공증을 받아 티켓을 붙입니다.")
        }

        return .alreadyDone
    }

    /// `codesign -dv` 출력에서 Team ID 를 뽑는다. 없으면 nil.
    static func teamID(fromCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(line.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    /// 서명 identity 이름에서 Team ID 를 뽑는다.
    ///
    /// `Developer ID Application: Example Inc. (ABCDE12345)` 의 괄호 안이다.
    /// 워커는 자기가 어느 팀인지 이 문자열로만 안다.
    public static func teamID(fromSigningIdentity identity: String) -> String? {
        guard let close = identity.lastIndex(of: ")"),
              let open = identity[..<close].lastIndex(of: "(")
        else {
            return nil
        }
        let value = String(identity[identity.index(after: open)..<close])
        // Team ID 는 영숫자 10자다. 이름에 든 다른 괄호를 잘못 집지 않게 한다.
        guard value.count == 10,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            return nil
        }
        return value
    }
}
