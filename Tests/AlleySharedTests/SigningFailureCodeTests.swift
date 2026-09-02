import Foundation
import Testing

@testable import AlleyShared

@Suite("서명 실패 코드")
struct SigningFailureCodeTests {
    @Test("다시 해볼 만한 갈래는 셋뿐이다")
    func retriableSet() {
        let retriable = SigningFailureCode.allCases.filter(\.isRetriable)
        // 재시도는 같은 버전을 다시 공증에 올린다. 그 대가를 치를 갈래를 늘릴 때는
        // 여기부터 고쳐야 한다.
        #expect(Set(retriable) == [.transferFailed, .appleServiceUnavailable, .timedOut])
    }

    @Test("분류하지 못한 실패는 다시 시도하지 않는다")
    func unknownIsNotRetriable() {
        // 근거는 isRetriable 의 주석과 ADR-0023 에 있다. 뒤집으려면 그쪽부터 읽을 것.
        #expect(SigningFailureCode.unknown.isRetriable == false)
    }

    @Test("모르는 코드를 받아도 디코딩이 깨지지 않는다")
    func unknownRawValueFoldsToUnknown() throws {
        // 워커가 서버보다 새로우면 서버가 모르는 코드가 온다. 그때 보고 전체를
        // 400 으로 튕기면 잡이 running 에 갇힌 채 15분을 기다린다.
        let json = Data(#"{"state":"failed","failureCode":"nobody_knows_this"}"#.utf8)
        let update = try JSONDecoder().decode(SigningJobUpdate.self, from: json)
        #expect(update.failureCode == .unknown)
    }

    @Test("코드가 없는 보고도 그대로 받아들인다")
    func missingCodeIsNil() throws {
        // 이 필드를 모르는 예전 워커가 보낸 보고다.
        let json = Data(#"{"state":"failed","failureReason":"뭔가 잘못됨"}"#.utf8)
        let update = try JSONDecoder().decode(SigningJobUpdate.self, from: json)
        #expect(update.failureCode == nil)
    }

    @Test("갈래마다 무엇을 해야 하는지가 적혀 있다")
    func everyCodeHasGuidance() {
        for code in SigningFailureCode.allCases {
            #expect(!SigningFailureGuidance.title(code).isEmpty)
            #expect(!SigningFailureGuidance.whatToDo(code).isEmpty)
        }
    }
}
