import AlleyProcess
import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

@Suite("실패 갈래 나누기")
struct FailureClassificationTests {
    @Test("번들을 찾지 못한 것은 번들 구조 문제다")
    func bundleErrorsAreLayoutProblems() {
        let notFound = AppBundle.BundleError.notFound(directory: URL(fileURLWithPath: "/tmp/x"))
        let ambiguous = AppBundle.BundleError.ambiguous(names: ["A.app", "B.app"])
        #expect(SigningFailureCode.classify(notFound) == .bundleLayoutInvalid)
        #expect(SigningFailureCode.classify(ambiguous) == .bundleLayoutInvalid)
    }

    @Test("프로필이 없는 권한은 entitlements 문제다")
    func missingProfileIsEntitlements() {
        let error = Entitlements.ValidationError.missingProfile(
            bundle: "도구.app", keys: ["com.apple.developer.icloud-services"]
        )
        #expect(SigningFailureCode.classify(error) == .entitlementsRejected)
    }

    @Test("파이프라인 오류는 자기가 들고 있는 갈래를 그대로 쓴다")
    func pipelineErrorCarriesItsOwnCode() {
        let failed = SigningPipeline.PipelineError.commandFailed(
            step: "서명 검증", code: .unsignedCodeRemains, detail: "남음"
        )
        #expect(SigningFailureCode.classify(failed) == .unsignedCodeRemains)

        let rejected = SigningPipeline.PipelineError.notarizationRejected(detail: "거절")
        #expect(SigningFailureCode.classify(rejected) == .notarizationRejected)
    }

    @Test("아티팩트를 주고받지 못한 것은 다시 해볼 만하다")
    func transferErrorsAreRetriable() {
        let transfer = WorkerClient.ClientError.transfer(action: "내려받기", detail: "curl: 7")
        let code = SigningFailureCode.classify(transfer)
        #expect(code == .transferFailed)
        #expect(code.isRetriable)
    }

    @Test("모르는 오류는 분류하지 못한 것으로 둔다")
    func unrecognizedErrorIsUnknown() {
        struct Odd: Error {}
        #expect(SigningFailureCode.classify(Odd()) == .unknown)
    }

    @Test("시간 초과는 종료 코드로 알아본다")
    func timeoutComesFromExitCode() {
        // Shell 은 제한 시간을 넘긴 프로세스를 죽이고 124 를 돌려준다.
        #expect(SigningPipeline.code(exitCode: 124, otherwise: .codesignFailed) == .timedOut)
        #expect(SigningPipeline.code(exitCode: 1, otherwise: .codesignFailed) == .codesignFailed)
    }

    @Test("codesign 출력에서 identity 문제를 좁힌다")
    func codesignIdentityMarkers() {
        // 여기만 문자열을 본다. 종료 코드로는 나눌 수 없다.
        #expect(
            SigningPipeline.codesignCode(from: "도구.app: no identity found")
                == .signingIdentityUnavailable
        )
        #expect(
            SigningPipeline.codesignCode(
                from: "The specified item could not be found in the keychain."
            ) == .signingIdentityUnavailable
        )
        // 번들 쪽 문제는 identity 와 섞이지 않아야 한다.
        #expect(
            SigningPipeline.codesignCode(from: "resource fork, Finder information, or similar detritus not allowed")
                == .codesignFailed
        )
    }

    @Test("공증은 제출이 접수된 경우에만 거절로 본다")
    func onlyReviewedSubmissionsAreRejections() {
        // 제출 자체가 안 되면 상태가 없다. 앱 내용과 무관한 실패라 다시 해볼 만하다.
        #expect(SigningPipeline.isRejection(nil) == false)
        #expect(SigningPipeline.isRejection(NotarySubmission(json: "{}")) == false)

        let invalid = NotarySubmission(json: #"{"id":"abc","status":"Invalid"}"#)
        #expect(SigningPipeline.isRejection(invalid))
    }
}
