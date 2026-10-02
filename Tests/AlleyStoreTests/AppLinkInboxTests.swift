import Foundation
import Testing

@testable import AlleyStoreCore

/// 공유 링크로 들어온 앱을 언제 여는가 (ADR-0072).
@Suite("공유 링크 열기")
@MainActor
struct AppLinkInboxTests {
    private let target = UUID()
    private let other = UUID()

    @Test("목록에 있으면 고르고 비운다")
    func selectsWhenListed() {
        let inbox = AppLinkInbox()
        inbox.receive(target)
        #expect(inbox.resolve(catalog: [other, target], isLoading: false) == .select(target))
        #expect(inbox.pending == nil)
    }

    /// 로그인 직후에는 목록이 비어 있다. 그때 "없다" 고 하면 곧 생길 앱을 놓친다.
    @Test("목록을 읽는 중이면 들고 기다린다")
    func waitsWhileLoading() {
        let inbox = AppLinkInbox()
        inbox.receive(target)
        #expect(inbox.resolve(catalog: [], isLoading: true) == .wait)
        #expect(inbox.pending == target)
        #expect(inbox.resolve(catalog: [target], isLoading: false) == .select(target))
    }

    @Test("다 읽었는데 없으면 알리고 비운다")
    func reportsMissing() {
        let inbox = AppLinkInbox()
        inbox.receive(target)
        #expect(inbox.resolve(catalog: [other], isLoading: false) == .notFound)
        #expect(inbox.pending == nil)
        // 한 번 알렸으면 목록이 다시 바뀌어도 또 알리지 않는다.
        #expect(inbox.resolve(catalog: [other], isLoading: false) == nil)
    }

    @Test("마지막에 누른 링크만 남는다")
    func keepsLatest() {
        let inbox = AppLinkInbox()
        inbox.receive(other)
        inbox.receive(target)
        #expect(inbox.resolve(catalog: [other, target], isLoading: false) == .select(target))
    }
}
