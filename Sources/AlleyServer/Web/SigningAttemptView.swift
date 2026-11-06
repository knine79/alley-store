import AlleyShared
import Foundation

/// 지난 시도 하나를 화면에 그릴 값 (이슈 #85).
///
/// 현재 시도는 버전 줄이 그대로 보여주므로, 이 타입은 접어 둘 **지난 시도**에만 쓴다.
/// 앱 상세와 스토어 앱 화면이 같은 모양으로 그리도록 한곳에 둔다.
struct SigningAttemptView: Encodable {
    var number: Int
    /// 배지 색을 고르는 잡 상태 원시값.
    var state: String
    /// 그 시도가 어떻게 끝났나. "완료" / "실패" 등.
    var stateName: String
    var isFailure: Bool
    var failureTitle: String?
    var failureCode: String?
    var failureAdvice: String?
    var failureReason: String?
    var log: String?
    /// 그 시도가 끝난(또는 시작된) 시각. 같은 날 여러 번 시도해도 구분되게 분까지.
    var finishedAt: DisplayDate?

    init(_ report: SigningJob.AttemptReport) {
        self.number = report.number
        self.state = report.state.rawValue
        self.stateName = report.state.displayName
        self.isFailure = report.state == .failed
        // 코드를 그대로 내보내지 않는다. 사람이 읽는 문장과 함께만 보여준다 (ADR-0023).
        self.failureTitle = report.failureCode.map(SigningFailureGuidance.title)
        self.failureCode = report.failureCode?.rawValue
        self.failureAdvice = report.failureCode.map(SigningFailureGuidance.whatToDo)
        self.failureReason = report.failureReason
        self.log = report.log
        self.finishedAt = (report.finishedAt ?? report.createdAt)
            .map(DateStyle.minute.display(from:))
    }
}

extension SigningJob.AttemptReport {
    /// 시도 목록을 현재 시도 하나와 지난 시도들로 나눈다 (이슈 #85).
    ///
    /// 현재 시도는 버전 줄이 그대로 그리고, 지난 시도는 최근 것이 위로 오도록 뒤집어
    /// 접어 둔다. 한 번도 안 올렸으면 현재가 nil 이고 지난 시도도 비어 있다.
    static func split(
        _ attempts: [SigningJob.AttemptReport]
    ) -> (current: SigningJob.AttemptReport?, past: [SigningAttemptView]) {
        guard let current = attempts.last else { return (nil, []) }
        let past = attempts.dropLast().reversed().map(SigningAttemptView.init)
        return (current, Array(past))
    }
}
