import Foundation

/// 앱 분류. 앱마다 하나이고, 스토어 앱이 목록을 거르는 데 쓴다 (이슈 #44).
///
/// **목록을 코드에 고정한다.** 자유 텍스트로 받으면 "개발 도구", "개발도구",
/// "Dev Tools" 가 따로 놀아 거를 수 없다. 조직마다 바꾸게 할 수도 있었지만 사내 앱은
/// 갈래가 많지 않고, 고칠 화면과 저장소를 하나 더 두는 값이 크다.
///
/// 저장과 API 에는 `rawValue` 가 오간다. 화면 이름(`title`)은 바꿔도 되지만 `rawValue`
/// 를 바꾸면 이미 저장된 분류가 풀린다.
public enum AppCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case developerTools = "developer-tools"
    case business
    case productivity
    case communication
    case design
    case utilities
    case dataAnalytics = "data-analytics"
    case other

    public var id: Self { self }

    public var title: String {
        switch self {
        case .developerTools: "개발 도구"
        case .business: "업무"
        case .productivity: "생산성"
        case .communication: "커뮤니케이션"
        case .design: "디자인"
        case .utilities: "유틸리티"
        case .dataAnalytics: "데이터·분석"
        case .other: "기타"
        }
    }

    /// 저장된 값을 분류로 읽는다. 모르는 값이면 nil 이고, 화면은 "미분류" 로 다룬다.
    ///
    /// 화면 이름으로 적힌 것도 받는다. 목록을 고정하기 전에 사람이 직접 적은 값이
    /// 남아 있을 수 있다.
    public init?(stored value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if let known = Self(rawValue: value) {
            self = known
        } else if let byTitle = Self.allCases.first(where: { $0.title == value }) {
            self = byTitle
        } else {
            return nil
        }
    }
}
