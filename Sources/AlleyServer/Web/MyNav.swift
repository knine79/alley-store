import Vapor

/// 내 설정 화면들 (ADR-0060 으로 둘이 됐다).
///
/// 관리자 탭과 같은 얼개다. 화면마다 `<nav>` 를 손으로 적으면 셋째 화면이 생길 때
/// 기존 템플릿을 전부 고쳐야 하고, `aria-current` 를 한 곳에서 뒤집는 것을 잊으면
/// 지금 있는 자리가 둘이 되거나 없어진다.
enum MyTab: String, CaseIterable, Sendable {
    case notifications
    case tokens

    var title: String {
        switch self {
        case .notifications: return "내 알림"
        case .tokens: return "내 토큰"
        }
    }

    var path: String {
        switch self {
        case .notifications: return "/me/notifications"
        case .tokens: return "/me/tokens"
        }
    }

    /// 화면에 그릴 탭들. 지금 보고 있는 것만 누를 수 없게 표시한다.
    static func links(current: MyTab) -> [AdminTabLink] {
        allCases.map {
            AdminTabLink(title: $0.title, path: $0.path, isCurrent: $0 == current)
        }
    }
}
