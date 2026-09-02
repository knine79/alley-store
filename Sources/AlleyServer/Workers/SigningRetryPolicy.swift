import AlleyShared
import Foundation

/// 실패한 서명 잡을 다시 내보낼 것인가.
///
/// 서버가 잡을 다시 내보내는 자리는 둘이고, 둘은 **서로 다른 사건**이다.
///
/// - **워커가 실패를 보고했다.** 무엇이 잘못됐는지 워커가 알고 있고 갈래(`SigningFailureCode`)
///   를 함께 보낸다. 인증서가 만료됐으면 세 번을 더 해도 같은 결과다.
/// - **워커에게서 소식이 끊겼다** (`StalledJobSweep`, ADR-0018). 워커가 죽었으니
///   아무것도 보고하지 못했다. **갈래가 없다.** 무엇이 잘못됐는지 모르는 상태이고,
///   워커 한 대가 재부팅된 것일 수도 있으니 다시 내보내는 것이 맞다.
///
/// 그래서 "갈래가 없다(nil)"와 "갈래를 정하지 못했다(`.unknown`)"를 섞지 않는다.
/// 앞은 보고 자체가 없었다는 뜻이고, 뒤는 워커가 보고했지만 우리가 분류하지 못했다는
/// 뜻이다. 뒤는 재시도하지 않는다 (`SigningFailureCode.isRetriable`, ADR-0023).
///
/// 시도 횟수(`attempt`)는 두 사건이 함께 쓴다. 나눠 쓰면 "일시 실패 보고 → 재시도 →
/// 워커 죽음 → 재시도" 를 오가는 잡이 어느 상한에도 걸리지 않는다.
enum SigningRetryPolicy {
    /// 같은 잡을 몇 번까지 내보낼지.
    ///
    /// 되돌리기만 하면 워커가 특정 빌드에서 죽는 경우에 큐를 무한히 도는 잡이 생긴다.
    /// 세 번이면 "저 워커 한 대가 그때 재부팅됐다" 정도의 우연은 넘어가고, 매번 죽는
    /// 빌드는 사람에게 넘어간다 (ADR-0018).
    static let maximumAttempts = 3

    enum Verdict: Equatable {
        /// 큐로 되돌린다. 다음 워커가 가져간다.
        case requeue
        /// 더 해봐야 소용없거나 상한을 넘겼다. 실패로 확정하고 사람에게 넘긴다.
        case giveUp
    }

    /// 워커가 실패를 보고했을 때.
    ///
    /// 갈래가 재시도해도 소용없다고 말하면 **시도 횟수를 쓰지 않고 바로 포기한다.**
    /// 만료된 인증서로 세 번 서명해 봐야 세 배로 기다릴 뿐이고, 그동안 큐의 뒤가 밀린다.
    static func verdict(reported code: SigningFailureCode?, attempt: Int) -> Verdict {
        guard let code, code.isRetriable else { return .giveUp }
        return attempt < maximumAttempts ? .requeue : .giveUp
    }

    /// 워커에게서 소식이 끊겼을 때 (`StalledJobSweep`).
    ///
    /// 이 잡에는 대개 갈래가 없다. 워커가 죽어서 아무 말도 못 했기 때문이다. 그럴
    /// 때는 예전처럼 시도 상한만 본다.
    ///
    /// `lastReported` 가 있는 경우는 **앞선 시도에서 워커가 일시적 실패를 보고해 큐로
    /// 돌아온 잡**이 다시 멈춘 것이다. 되돌리지 않는 갈래는 보고받는 자리에서 이미
    /// 실패로 확정되므로 여기까지 오지 않지만, 그 규칙이 한쪽에서만 바뀌어도 잡이
    /// 계속 도는 일은 없어야 해서 여기서도 물어본다.
    static func verdict(stalledAttempt attempt: Int, lastReported code: SigningFailureCode?) -> Verdict {
        if let code, !code.isRetriable { return .giveUp }
        return attempt < maximumAttempts ? .requeue : .giveUp
    }
}
