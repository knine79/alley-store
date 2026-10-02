import Foundation

/// 앱 목록에 거르기·정렬·검색을 한 번에 건다. 스토어 앱과 웹 콘솔이 같은 것을 부른다.
///
/// **조건이 같으면 두 곳의 순서가 같아야 한다** (이슈 #56). 같은 앱을 두 곳에서 다르게
/// 찾게 되면 한쪽을 믿지 않게 된다. 거르고, 늘어놓고, 찾는 순서까지 여기 한 곳에 둔다.
/// 각자 이어 붙이면 한쪽만 순서가 바뀌는 날이 온다.
public enum CatalogFilter {
    /// 목록에 실제로 있는 분류. 고르면 빈 목록이 되는 칸은 내지 않는다.
    public static func categories(in apps: [AppDTO]) -> [AppCategory] {
        let present = Set(apps.compactMap { AppCategory(stored: $0.category) })
        return AppCategory.allCases.filter(present.contains)
    }

    /// 실제로 걸 분류. 목록에 없는 분류면 nil 이고 거르지 않는다.
    ///
    /// 고른 분류의 앱이 목록에서 사라지면 거르기 칸도 사라진다. 그때 빈 목록에 갇히지
    /// 않게 한다. 웹에서는 남이 보낸 주소의 분류가 내 목록에 없을 때도 그렇다.
    public static func effectiveCategory(_ category: AppCategory?, in apps: [AppDTO]) -> AppCategory? {
        category.flatMap { categories(in: apps).contains($0) ? $0 : nil }
    }

    /// 분류로 거르고, 늘어놓고, 검색어로 고른다.
    ///
    /// 검색이 맨 뒤인 이유는 `CatalogSearch.filter` 가 받은 순서를 지키기 때문이다.
    /// 같은 자리에 걸린 것끼리는 고른 정렬대로 남는다.
    public static func apply(
        _ apps: [AppDTO],
        category: AppCategory?,
        sort: CatalogSort,
        query: String
    ) -> [AppDTO] {
        let active = effectiveCategory(category, in: apps)
        let inCategory = active.map { category in
            apps.filter { AppCategory(stored: $0.category) == category }
        } ?? apps
        return CatalogSearch.filter(sort.sorted(inCategory), query: query)
    }
}
