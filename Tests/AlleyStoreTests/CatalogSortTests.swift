import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

@Suite("앱 목록 정렬")
struct CatalogSortTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func app(
        _ name: String,
        rating: (average: Double, count: Int)? = nil,
        registeredDaysAgo: Double = 0,
        releasedDaysAgo: Double? = nil
    ) -> AppDTO {
        let id = UUID()
        let version = releasedDaysAgo.map { days in
            VersionDTO(
                id: UUID(), appID: id, shortVersion: "1.0", buildNumber: 1, state: .released,
                createdAt: base.addingTimeInterval(-days * 86_400 - 60),
                releasedAt: base.addingTimeInterval(-days * 86_400)
            )
        }
        return AppDTO(
            id: id, bundleID: "com.example.\(name)", name: name, ownerID: UUID(),
            latestReleasedVersion: version,
            rating: rating.map { RatingSummary(count: $0.count, average: $0.average) },
            createdAt: base.addingTimeInterval(-registeredDaysAgo * 86_400),
            updatedAt: base
        )
    }

    private func names(_ sort: CatalogSort, _ apps: [AppDTO]) -> [String] {
        sort.sorted(apps).map(\.name)
    }

    @Test("이름순은 숫자를 값으로 견준다")
    func byName() {
        // 한글과 영문 중 무엇이 먼저인지는 사용자 로케일이 정한다. 그래서 섞지 않는다.
        #expect(names(.name, [app("앱 10"), app("앱 2")]) == ["앱 2", "앱 10"])
        #expect(names(.name, [app("Beta"), app("alpha")]) == ["alpha", "Beta"])
    }

    @Test("별점순은 높은 것부터, 별점 없는 앱은 맨 뒤")
    func byRating() {
        let apps = [
            app("없음"),
            app("낮음", rating: (1.0, 3)),
            app("높음", rating: (4.8, 2)),
        ]
        #expect(names(.rating, apps) == ["높음", "낮음", "없음"])
    }

    @Test("리뷰 많은 순은 별점 개수로, 없는 앱은 맨 뒤")
    func byReviewCount() {
        let apps = [
            app("없음"),
            app("빈 요약", rating: (0, 0)),
            app("적음", rating: (5.0, 1)),
            app("많음", rating: (3.0, 30)),
        ]
        #expect(names(.reviewCount, apps) == ["많음", "적음", "빈 요약", "없음"])
    }

    @Test("최신 등록순과 최근 업데이트순은 서로 다른 시각을 본다")
    func byDates() {
        // 오래전에 등록했지만 어제 업데이트한 앱과, 최근에 등록하고 그대로인 앱.
        let apps = [
            app("오래된 앱", registeredDaysAgo: 100, releasedDaysAgo: 1),
            app("새 앱", registeredDaysAgo: 3, releasedDaysAgo: 3),
        ]
        #expect(names(.newest, apps) == ["새 앱", "오래된 앱"])
        #expect(names(.recentlyUpdated, apps) == ["오래된 앱", "새 앱"])
    }

    @Test("값이 같으면 이름순으로 가른다")
    func tiesFallBackToName() {
        // 새로 고칠 때마다 자리가 바뀌지 않아야 한다.
        let apps = [app("다", rating: (4.0, 2)), app("가", rating: (4.0, 2)), app("나", rating: (4.0, 2))]
        #expect(names(.rating, apps) == ["가", "나", "다"])
        #expect(names(.reviewCount, apps) == ["가", "나", "다"])
    }

    @Test("저장된 값으로 되살린다")
    func rawValuesAreStable() {
        // `@AppStorage` 에 이 값이 들어간다. 바뀌면 사람이 고른 정렬이 풀린다.
        #expect(CatalogSort.allCases.map(\.rawValue)
            == ["name", "rating", "reviewCount", "newest", "recentlyUpdated"])
    }
}
