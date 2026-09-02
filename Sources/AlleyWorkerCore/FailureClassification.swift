import AlleyShared
import Foundation

extension SigningFailureCode {
    /// 워커가 잡을 처리하다 던진 오류를 갈래로 나눈다.
    ///
    /// **오류 타입에서만 뽑는다.** 파이프라인이 던지는 오류는 이미 case 로 나뉘어
    /// 있으므로 메시지를 다시 읽을 이유가 없다. 문자열을 보는 자리는 딱 두 곳이고
    /// (`SigningPipeline.codesignCode`, `SigningPipeline.isRejection`), 둘 다 종료
    /// 코드로는 나눌 수 없어서 어쩔 수 없이 그렇게 하는 곳이다. 그 한계는 각 함수의
    /// 주석에 적어뒀다.
    ///
    /// 여기서 걸리지 않은 오류는 `unknown` 이고, 그것은 **다시 시도하지 않는다**는
    /// 뜻이다. 근거는 `isRetriable` 과 ADR-0023 에 있다. 새로 생긴 실패가 반복해서
    /// `unknown` 으로 들어온다면 갈래를 하나 더 만들 때가 된 것이다.
    public static func classify(_ error: any Error) -> SigningFailureCode {
        switch error {
        case let pipeline as SigningPipeline.PipelineError:
            return pipeline.failureCode

        case is Entitlements.ValidationError:
            // 프로필이 필요한 권한인데 번들에 프로필이 없다. 앱을 다시 빌드해야 한다.
            return .entitlementsRejected

        case is AppBundle.BundleError:
            // zip 안에 `.app` 이 없거나 여러 개다.
            return .bundleLayoutInvalid

        case let client as WorkerClient.ClientError:
            switch client {
            case .transfer, .transport:
                // 아티팩트를 주고받지 못했다. 네트워크나 스토리지 문제다.
                return .transferFailed
            case .badResponse, .malformedPayload:
                // 서버가 우리 요청을 거절했다. 잡을 다시 내보낸다고 달라지지 않는다.
                return .unknown
            }

        default:
            return .unknown
        }
    }
}
