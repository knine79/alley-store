import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

@Suite("연결 배너")
@MainActor
struct ConnectionNoticeTests {
    private func readyModel() -> StoreModel {
        let model = StoreModel(builtInServer: URL(string: "https://store.example.com"))
        model.stage(
            meta: StoreMeta(storeName: "Example Store", callbackURLScheme: "com.example.store"),
            user: UserDTO(id: UUID(), email: "alice@example.com", name: "Alice", role: .user),
            apps: []
        )
        return model
    }

    @Test("서버에 닿지 못한 실패만 연결 실패로 본다")
    func classifiesConnectionFailures() {
        #expect(StoreModel.isConnectionFailure(StoreClient.ClientError.unreachable("offline")))
        #expect(StoreModel.isConnectionFailure(
            StoreClient.ClientError.unreachable("offline", code: .notConnectedToInternet)))
        #expect(StoreModel.isConnectionFailure(StoreClient.ClientError.unreachable("slow", code: .timedOut)))
        // 인증서가 만료된 것은 기다린다고 낫지 않는다. 원인을 얼럿으로 보인다.
        #expect(!StoreModel.isConnectionFailure(
            StoreClient.ClientError.unreachable("tls", code: .serverCertificateUntrusted)))
        // 내려받기는 스토리지에서 받는다. 스토어 서버가 끊긴 것이 아니다.
        #expect(!StoreModel.isConnectionFailure(URLError(.networkConnectionLost)))
        // 서버가 답을 준 실패는 다시 붙어도 그대로다. 배너로 띄우면 "자동으로 다시 붙습니다"
        // 가 거짓말이 된다.
        #expect(!StoreModel.isConnectionFailure(StoreClient.ClientError.server(status: 500, reason: nil)))
        #expect(!StoreModel.isConnectionFailure(StoreClient.ClientError.malformedResponse))
        #expect(!StoreModel.isConnectionFailure(StoreClient.ClientError.unauthorized))
        #expect(!StoreModel.isConnectionFailure(URLError(.badServerResponse)))
    }

    @Test("끊기면 배너가 뜨고 얼럿은 뜨지 않는다")
    func lostShowsBannerNotAlert() {
        let model = readyModel()
        model.markConnectionLost()
        #expect(model.connectionNotice == .lost)
        #expect(model.errorMessage == nil)
    }

    @Test("서버가 답을 준 실패는 그대로 얼럿이다")
    func serverFailureStaysAlert() {
        let model = readyModel()
        model.report(StoreClient.ClientError.server(status: 500, reason: "고장"))
        #expect(model.connectionNotice == nil)
        #expect(model.errorMessage == "고장")
    }

    @Test("끊긴 동안 서버가 오류로 답하면 배너를 걷고 얼럿 하나만 띄운다")
    func serverAnswerEndsLostState() {
        // 서버를 다시 띄우는 동안 프록시가 502 를 준다. 답을 받았으니 연결은 된 것이다.
        // 배너가 남으면 재시도가 이어지고 그때마다 얼럿이 뜬다.
        let model = readyModel()
        model.markConnectionLost()
        model.report(StoreClient.ClientError.server(status: 502, reason: nil))
        #expect(model.connectionNotice == .restored)
        #expect(model.errorMessage != nil)
    }

    @Test("거둔 요청은 배너도 얼럿도 띄우지 않는다")
    func cancellationIsSilent() {
        // 앱을 빨리 바꿔 고르면 앞 앱의 피드백 요청이 거둬진다. 끊긴 것이 아니다.
        let model = readyModel()
        model.report(CancellationError())
        model.report(URLError(.cancelled))
        #expect(model.connectionNotice == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("끊긴 적이 없으면 다시 붙었다고 하지 않는다")
    func restoredOnlyAfterLost() {
        let model = readyModel()
        model.markConnectionRestored()
        #expect(model.connectionNotice == nil)
    }

    @Test("다시 붙은 배너는 잠시 뒤 사라진다")
    func restoredDismissesItself() async throws {
        let model = readyModel()
        model.restoredNoticeDuration = .milliseconds(50)
        model.markConnectionLost()
        model.markConnectionRestored()
        #expect(model.connectionNotice == .restored)

        try await Task.sleep(for: .milliseconds(300))
        #expect(model.connectionNotice == nil)
    }

    @Test("다시 붙은 배너가 떠 있는 동안 또 끊기면 끊긴 배너가 남는다")
    func lostAgainOverridesRestored() async throws {
        let model = readyModel()
        model.restoredNoticeDuration = .milliseconds(50)
        model.markConnectionLost()
        model.markConnectionRestored()
        model.markConnectionLost()

        try await Task.sleep(for: .milliseconds(300))
        #expect(model.connectionNotice == .lost)
    }

    @Test("붙기 전 화면에서는 배너를 띄우지 않는다")
    func noBannerWhileConnecting() {
        // 그 화면이 통째로 "연결하지 못했습니다" 를 말한다. 배너까지 뜨면 같은 말을 두 번 한다.
        let model = StoreModel(builtInServer: URL(string: "https://store.example.com"))
        model.markConnectionLost()
        #expect(model.connectionNotice == nil)
    }

    @Test("로그아웃하면 배너를 걷는다")
    func signOutClears() {
        let model = readyModel()
        model.markConnectionLost()
        model.signOut()
        #expect(model.connectionNotice == nil)
    }
}
