import Foundation

/// 서명 잡이 왜 실패했는지를 담는 갈래.
///
/// 지금까지 워커가 서버에 넘긴 것은 자유 문자열뿐이었습니다. 서버는 그것을 화면에
/// 옮겨 적는 것 말고 아무것도 할 수 없었고, 특히 **다시 해볼 가치가 있는 실패인지**
/// 판단할 근거가 없었습니다. 인증서가 만료된 잡을 세 번 내보내는 것과 Apple 이
/// 잠깐 답하지 않은 잡을 한 번에 포기하는 것은 둘 다 틀린 선택입니다 (ADR-0023).
///
/// 그래서 갈래를 코드로 만들고, **재시도 여부의 판단을 코드 자신이 갖게** 합니다
/// (`isRetriable`). 서버가 문자열을 다시 해석하는 일은 없어야 합니다.
///
/// 값은 워커가 늘릴 수 있습니다. 워커와 서버의 배포 시점이 다르므로 서버가 모르는
/// 값을 받을 수 있고, 그때는 `unknown` 으로 접습니다 (아래 디코딩 참고).
public enum SigningFailureCode: String, Codable, Sendable, CaseIterable, Equatable {

    // MARK: - 다시 해도 같은 결과다

    /// 서명 identity 가 워커 키체인에 없거나 만료됐다.
    case signingIdentityUnavailable = "signing_identity_unavailable"
    /// `codesign` 이 실패했는데 identity 문제는 아니다. 번들 자체에 문제가 있다.
    case codesignFailed = "codesign_failed"
    /// entitlements 가 없거나(JIT 누락), 프로필이 필요한 권한인데 프로필이 없다.
    case entitlementsRejected = "entitlements_rejected"
    /// zip 안에서 서명할 `.app` 을 정할 수 없다. 없거나 여러 개다.
    case bundleLayoutInvalid = "bundle_layout_invalid"
    /// 올린 번들이 밝히는 번들 ID 가 등록된 앱과 다르다. 서명하기 전에 멈춘다.
    case bundleIdentifierMismatch = "bundle_identifier_mismatch"
    /// 우리가 서명 대상에서 지나친 코드가 번들에 남았다. 공증에서 거절된다.
    case unsignedCodeRemains = "unsigned_code_remains"
    /// Apple 이 내용을 보고 공증을 거절했다.
    case notarizationRejected = "notarization_rejected"
    /// 갈래를 정하지 못했다. 재시도하지 않는다 (아래 `isRetriable` 참고).
    case unknown = "unknown"

    // MARK: - 다시 하면 될 수도 있다

    /// 아티팩트를 내려받거나 올리지 못했다. 네트워크나 오브젝트 스토리지 문제다.
    case transferFailed = "transfer_failed"
    /// 공증 서비스에 닿지 못했다. 제출도 티켓 첨부도 Apple 서버가 살아 있어야 한다.
    case appleServiceUnavailable = "apple_service_unavailable"
    /// 명령이 제한 시간 안에 끝나지 않았다.
    case timedOut = "timed_out"

    /// 같은 잡을 다시 내보낼 가치가 있는가.
    ///
    /// **`unknown` 은 재시도하지 않습니다.** 어느 쪽으로 두든 대가가 있어서 오래
    /// 고민한 자리입니다. 근거는 셋입니다 (ADR-0023 에 자세히 적었습니다).
    ///
    /// 첫째, 잘못된 재시도에는 우리 밖으로 나가는 부수효과가 있습니다. 같은 버전이
    /// 공증에 두 번 올라갑니다. ADR-0018 이 멈춤 판정을 15분으로 길게 잡은 것도
    /// 같은 이유였습니다. 이 레포는 이미 "의심스러우면 다시 내보내지 않는다" 쪽으로
    /// 정해둔 곳입니다.
    ///
    /// 둘째, 분류하지 못했다는 것은 우리가 그 실패를 아직 모른다는 뜻입니다. 조용히
    /// 세 번 돌려버리면 그 사실이 아무 데도 드러나지 않고, 갈래를 늘려야 한다는
    /// 신호가 묻힙니다. 실패로 확정하면 사람이 로그를 보고 갈래를 하나 더 만듭니다.
    ///
    /// 셋째, 워커가 서버보다 새로워서 서버가 모르는 코드를 받는 경우입니다. 그때도
    /// `unknown` 이 되는데, 재시도하지 않는 쪽이 **코드가 없던 시절과 같은 동작**
    /// 입니다. 버전이 어긋났을 때 새 동작이 튀어나오는 것보다 낫습니다.
    ///
    /// 대가는 분명합니다. 우리가 갈래로 만들지 못한 일시적 실패는 사람이 다시
    /// 올려야 합니다. 그 대가를 줄이는 방법은 기본값을 뒤집는 것이 아니라 갈래를
    /// 늘리는 것입니다.
    public var isRetriable: Bool {
        switch self {
        case .transferFailed, .appleServiceUnavailable, .timedOut:
            return true
        case .signingIdentityUnavailable, .codesignFailed, .entitlementsRejected,
             .bundleLayoutInvalid, .bundleIdentifierMismatch, .unsignedCodeRemains,
             .notarizationRejected, .unknown:
            return false
        }
    }

    /// 모르는 값을 받아도 던지지 않는다.
    ///
    /// 합성 디코더는 모르는 rawValue 에서 오류를 냅니다. 그러면 새 워커가 보낸 실패
    /// 보고 **전체**가 400 으로 튕기고, 잡은 `running` 에 남아 멈춘 잡 회수에 걸릴
    /// 때까지 15분을 기다립니다. 코드 하나를 몰라서 실패 보고를 통째로 잃는 것은
    /// 어떤 이득과도 바꿀 수 없습니다.
    ///
    /// 대신 원래 문자열은 여기서 사라집니다. 지원 문의 때 필요한 원문은 잡 로그에
    /// 남아 있는 워커의 실패 메시지에서 찾아야 합니다.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SigningFailureCode(rawValue: raw) ?? .unknown
    }
}

/// 오류 코드마다 사람에게 하는 말.
///
/// `EntitlementsGuidance` 와 같은 이유로 한곳에 모읍니다. 서버 화면과 CLI 가 같은
/// 실패를 각자 다른 문장으로 설명하면 읽는 사람은 매번 처음 보는 문제를 만납니다.
///
/// **코드 자체를 문장 대신 내보내지 마세요.** `unsigned_code_remains` 를 보고
/// 무엇을 해야 하는지 아는 사람은 이 코드를 쓴 사람뿐입니다. 화면에는 문장을 쓰고,
/// 코드는 지원 문의에 적을 수 있도록 그 옆에 작게 둡니다.
public enum SigningFailureGuidance {
    /// 목록에서 한 줄로 읽을 이름.
    public static func title(_ code: SigningFailureCode) -> String {
        switch code {
        case .signingIdentityUnavailable: return "서명 identity 문제"
        case .codesignFailed: return "서명 실패"
        case .entitlementsRejected: return "entitlements 문제"
        case .bundleLayoutInvalid: return "번들 구조 문제"
        case .bundleIdentifierMismatch: return "번들 ID 불일치"
        case .unsignedCodeRemains: return "서명되지 않은 코드가 남음"
        case .notarizationRejected: return "공증 거절"
        case .transferFailed: return "파일 전송 실패"
        case .appleServiceUnavailable: return "Apple 서버에 닿지 못함"
        case .timedOut: return "시간 초과"
        case .unknown: return "분류하지 못한 실패"
        }
    }

    /// 무엇을 해야 하는가. 화면에 그대로 붙인다.
    public static func whatToDo(_ code: SigningFailureCode) -> String {
        switch code {
        case .signingIdentityUnavailable:
            return """
                워커 머신 키체인의 Developer ID 인증서를 확인하세요. 만료일은 관리 > 앱 서명에서 \
                봅니다. 인증서를 새로 받았다면 워커 설정의 서명 identity 이름도 맞춰야 합니다.
                """
        case .codesignFailed:
            return """
                번들 안에 codesign 이 받아들이지 못하는 것이 있습니다. 리소스 포크나 확장 속성이 \
                붙은 파일, 이미 깨진 프레임워크 서명이 흔합니다. 어디서 걸렸는지는 로그 마지막 \
                줄에 있습니다.
                """
        case .entitlementsRejected:
            // **한 문장이다.** 이 자리는 세 화면이 함께 쓰는데(앱 상세·워커 잡 목록·
            // 스토어 앱), 붙이는 칸은 앱 상세에만 있다. 예전 문구는 "바로 아래 칸에"
            // 라고 가리켜서 나머지 두 화면에서는 없는 칸을 가리켰고, 정작 앱 상세
            // 에서는 칸이 눈앞에 있는데 그 설명을 한 문단 더 읽어야 했다.
            //
            // 어디서 찾는지와 CLI 로 올리는 법은 붙이는 칸 옆에서 접어 보여준다.
            return "entitlements 파일을 붙여 다시 시도해야 합니다."
        case .bundleLayoutInvalid:
            return """
                zip 최상위에 .app 하나만 담아 다시 올리세요. 앱이 없거나 여러 개면 무엇을 \
                배포할지 서버가 고를 수 없습니다.
                """
        case .bundleIdentifierMismatch:
            return """
                다른 앱의 빌드를 올렸거나 빌드 설정의 번들 ID 가 바뀐 것입니다. 서명 전에 멈췄으니 \
                조직 이름이 잘못 붙지는 않았습니다. 번들 ID 가 정말 바뀐 것이라면 관리자에게 앱을 \
                새로 등록해 달라고 하세요.
                """
        case .unsignedCodeRemains:
            return """
                번들에 서명하지 못한 코드가 남았습니다. 앱이 아니라 워커가 서명 대상을 놓친 것일 \
                수 있으니 로그의 경로와 함께 알려주세요.
                """
        case .notarizationRejected:
            return """
                대개 Hardened Runtime 이 없거나 서명이 빠진 바이너리입니다. 어느 파일인지는 로그 \
                끝의 공증 로그에 있습니다. 고쳐서 다시 올려야 합니다.
                """
        case .transferFailed:
            return """
                서버가 자동으로 다시 시도합니다. 계속 실패하면 오브젝트 스토리지와 워커 머신의 \
                네트워크를 확인하세요.
                """
        case .appleServiceUnavailable:
            return """
                서버가 자동으로 다시 시도합니다. 계속 실패하면 Apple 시스템 상태와 워커의 공증 \
                자격증명(notary profile)을 확인하세요.
                """
        case .timedOut:
            return """
                서버가 자동으로 다시 시도합니다. 앱이 아주 크거나 공증이 밀리면 일어납니다.
                """
        case .unknown:
            return """
                아직 갈래로 나누지 못한 실패라 자동으로 다시 시도하지 않습니다. 로그를 그대로 \
                전달해 주세요.
                """
        }
    }
}
