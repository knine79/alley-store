import AlleyShared
import Foundation
import Testing

@Suite("앱 목록 거르기")
struct CatalogFilterTests {
    private func app(
        _ name: String,
        category: AppCategory? = nil,
        tags: [String]? = nil,
        rating: Double? = nil
    ) -> AppDTO {
        AppDTO(
            id: UUID(), bundleID: "com.example.\(UUID().uuidString.prefix(6))", name: name,
            category: category?.rawValue, tags: tags, ownerID: UUID(),
            rating: rating.map { RatingSummary(count: 1, average: $0) },
            createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("분류 칸은 목록에 있는 것만, 정해진 순서로 낸다")
    func categoriesPresentInOrder() {
        let apps = [app("가", category: .design), app("나", category: .developerTools), app("다")]
        #expect(CatalogFilter.categories(in: apps) == [.developerTools, .design])
    }

    @Test("목록에 없는 분류를 고르면 거르지 않는다")
    func ignoresAbsentCategory() {
        // 남이 보낸 주소의 분류가 내 목록에 없을 수 있다. 빈 목록에 가두지 않는다.
        let apps = [app("가", category: .design), app("나")]
        #expect(CatalogFilter.effectiveCategory(.business, in: apps) == nil)
        #expect(CatalogFilter.apply(apps, category: .business, sort: .name, query: "").count == 2)
    }

    @Test("분류로 거른 뒤 고른 정렬을 지키며 찾는다")
    func filtersSortsThenSearches() {
        let apps = [
            app("낮은 별점", category: .design, tags: ["색"], rating: 2),
            app("높은 별점", category: .design, tags: ["색"], rating: 5),
            app("색 고르기", category: .design, rating: 1),
            app("다른 분류", category: .business, tags: ["색"], rating: 4),
        ]
        let result = CatalogFilter.apply(apps, category: .design, sort: .rating, query: "색")
        // 이름에 걸린 것이 먼저, 태그에 걸린 것끼리는 별점순이다.
        #expect(result.map(\.name) == ["색 고르기", "높은 별점", "낮은 별점"])
    }
}
