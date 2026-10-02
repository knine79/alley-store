import Foundation

/// 검색어에 맞는 앱을 고른다.
///
/// 이름만 보면 기능이나 만든 사람으로는 찾을 수 없다. 그래서 개발자 이름, 태그, 소개,
/// 설명까지 본다. 대신 **어디에 걸렸는지에 따라 순서를 매긴다.** 이름이 맞는 앱이
/// 설명에 낱말 하나 걸린 앱 밑에 깔리면 검색을 믿지 않게 된다.
public enum CatalogSearch {
    /// 걸린 자리. 앞에 있을수록 먼저 보인다.
    public enum Match: Int, Comparable, Sendable {
        case name
        case tag
        case developer
        case text

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 맞는 앱만 남긴다. 같은 자리에 걸린 것끼리는 받은 순서를 지킨다.
    ///
    /// 받은 순서는 사람이 고른 정렬이다 (`CatalogSort`). 검색이 그것을 흩뜨리면 정렬을
    /// 고른 뜻이 없어진다.
    public static func filter(_ apps: [AppDTO], query: String) -> [AppDTO] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.enumerated()
            .compactMap { offset, app in match(app, query: query).map { (app, $0, offset) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }

    /// 가장 앞자리의 걸린 곳. 안 걸리면 nil.
    public static func match(_ app: AppDTO, query: String) -> Match? {
        func contains(_ field: String?) -> Bool {
            field?.localizedCaseInsensitiveContains(query) == true
        }
        // 번들 ID 는 이름과 같은 자리로 친다. 그 값을 아는 사람은 그 앱을 찾는 것이다.
        if contains(app.name) || contains(app.bundleID) { return .name }
        if app.tags?.contains(where: contains) == true { return .tag }
        if app.developerNames?.contains(where: contains) == true { return .developer }
        if contains(app.summary) || contains(app.description) { return .text }
        return nil
    }
}
