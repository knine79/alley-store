/// 관리자 화면 여섯 개를 묶는 탭.
///
/// 전에는 화면마다 제목 오른쪽에 다른 부분집합을 링크로 놓았다. 통계에서는 역할
/// 관리와 앱 서명으로 갈 수 없었고, 앱 서명에서는 역할 관리로 갈 수 없었다.
/// 순서도 화면마다 달랐다. 그래서 "지금 어디에 있고 어디로 갈 수 있나" 가 화면마다
/// 다르게 보였다.
///
/// 이제 목록과 순서가 여기 한 곳에만 있다. 화면을 추가하면 `case` 하나를 넣는 것으로
/// 다섯 화면 전부에 같이 나온다. 화면별로 링크를 손으로 적는 자리가 없으니 다시
/// 어긋날 수 없다.
///
/// ## 순서
///
/// `설정 → 스토어 앱 → 사람 → 우리 기계 → Apple → 통계`
///
/// 앞의 다섯은 **바꾸는** 화면이고 마지막 하나는 **보는** 화면이다. 바꾸는 다섯은
/// 설정 대상이 가까운 것에서 먼 것으로 간다. 스토어 자신 → 스토어가 내놓는 앱 →
/// 그 안의 사람 → 우리가 돌리는 기계 → Apple 쪽 계정. 서명 워커와 앱 서명이
/// 붙어 있는 것은 워커가 그 인증서로 서명하기 때문이다. 통계는 바꿀 것이 없고
/// 다른 화면이 통계에 기대지도 않아서 끝이다.
///
/// 스토어 앱이 스토어 설정 바로 옆인 것은 둘 다 "스토어 자신" 이기 때문이다. 다만
/// 성격이 달라서 화면을 나눴다. 설정은 바꾸면 다음 요청부터 반영되고, 스토어 앱은
/// 바꾼 뒤 **다시 빌드해 올려야** 반영된다. 한 화면에 섞으면 저장 버튼 하나가 두
/// 가지 뜻을 갖는다.
///
/// 스토어 설정이 첫 칸인 데는 이유가 하나 더 있다. 껍데기의 "관리" 링크가
/// `/admin/settings` 로 오므로, 들어온 자리가 첫 칸이어야 지금 어디인지 헷갈리지
/// 않는다 (`AdminPagesController.home` 도 여기로 보낸다).
///
/// "자주 쓰는 것부터" 로 두지 않았다. 무엇을 자주 쓰는지 아직 모르고, 추측으로 정하면
/// 다음 사람이 또 근거 없이 바꾼다. 구조로 정한 순서는 근거를 적을 수 있다.
enum AdminTab: String, CaseIterable, Sendable {
    case settings
    case storeApp
    case users
    case workers
    case portal
    case notifications
    case stats

    /// 탭에 적히는 글자. 각 화면의 `<h1>` 과 브라우저 탭 제목으로도 쓴다
    /// (`Request.pageContext(title:adminTab:)` 참고). 한 곳에서 나오므로 탭 이름과
    /// 화면 제목이 갈라질 수 없다.
    var title: String {
        switch self {
        case .settings: "스토어 설정"
        case .storeApp: "스토어 앱"
        case .users: "역할 관리"
        case .workers: "서명 워커"
        // "개발자 포털" 이었다. 이 스토어에도 developer 역할이 있어서 그 사람들의
        // 화면으로 읽혔다. 여기서 보는 것은 Apple 쪽 자격이다.
        case .portal: "앱 서명"
        // 여기서 정하는 것은 운영 알림 한 갈래다. 앱 채널은 앱 상세에, 개인 알림은
        // 내 알림에 있다. 셋이 받는 사람도 정하는 사람도 달라서 화면을 나눴다.
        case .notifications: "알림"
        case .stats: "통계"
        }
    }

    var path: String {
        switch self {
        case .settings: "/admin/settings"
        case .storeApp: "/admin/store-app"
        case .users: "/admin/users"
        case .workers: "/admin/workers"
        case .portal: "/admin/portal"
        case .notifications: "/admin/notifications"
        case .stats: "/admin/stats"
        }
    }

    /// 지금 보고 있는 화면을 표시한 탭 목록.
    ///
    /// 현재 탭도 목록에서 빼지 않는다. 여섯 칸이 늘 같은 자리에 있어야 화면을 옮겨도
    /// 탭이 움직이지 않는다. 대신 `isCurrent` 를 보고 템플릿이 링크가 아니라 글자로
    /// 그린다.
    static func links(current: AdminTab) -> [AdminTabLink] {
        allCases.map {
            AdminTabLink(title: $0.title, path: $0.path, isCurrent: $0 == current)
        }
    }
}

/// 탭 하나를 그리는 데 필요한 것.
struct AdminTabLink: Encodable {
    var title: String
    var path: String
    /// 지금 보고 있는 화면인지. 참이면 템플릿이 `<a>` 대신 `<span>` 을 낸다.
    /// 지금 있는 곳을 누를 수 있게 두면 아무 일도 안 일어나는 클릭이 된다.
    var isCurrent: Bool
}
