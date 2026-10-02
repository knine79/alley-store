import Foundation
import Observation

/// 공유 링크로 들어온, 아직 열지 못한 앱 (ADR-0072).
///
/// 링크는 앱이 어느 단계에 있든 들어온다. 로그인 전이면 목록이 없어서 열 수 없다.
/// **버리지 않고 들고 있다가 목록이 생기면 연다.** 스토어 앱을 처음 받은 사람은 링크를
/// 눌러 앱을 띄우고, 로그인하고, 그다음에 보려던 앱을 봐야 한다. 로그인 뒤 링크를 한 번
/// 더 누르라고 하면 그 사람은 링크가 안 된다고 생각한다.
///
/// Apple Event 처리기(`AppDelegate`)가 넣고 목록 화면(`CatalogView`)이 꺼내므로 둘 다
/// 닿는 자리에 하나만 둔다. 마지막 것만 남긴다. 여러 개를 차례로 열 이유가 없다.
@MainActor
@Observable
final class AppLinkInbox {
    static let shared = AppLinkInbox()

    /// 열기를 기다리는 앱.
    private(set) var pending: UUID?

    func receive(_ appID: UUID) {
        pending = appID
    }

    /// 목록을 보고 지금 할 일을 정한다. 결과가 기다림이 아니면 들고 있던 것을 비운다.
    func resolve(catalog: [UUID], isLoading: Bool) -> Resolution? {
        guard let pending else { return nil }
        let resolution = Self.resolution(for: pending, catalog: catalog, isLoading: isLoading)
        if resolution != .wait { self.pending = nil }
        return resolution
    }

    enum Resolution: Equatable {
        case select(UUID)
        /// 목록을 읽는 중이다. 다 읽으면 다시 본다.
        case wait
        /// 목록에 없다. 출시 전이거나 내려갔거나, 스토어 앱 자신이다.
        case notFound
    }

    /// 목록을 다 읽기 전에는 판단하지 않는다. 로그인 직후에는 목록이 비어 있고, 그때
    /// "없다" 고 하면 곧 생길 앱을 놓친다.
    nonisolated static func resolution(for appID: UUID, catalog: [UUID], isLoading: Bool) -> Resolution {
        if catalog.contains(appID) { return .select(appID) }
        return isLoading ? .wait : .notFound
    }
}
