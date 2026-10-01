import AlleyShared
import Foundation

/// 앱 목록을 늘어놓는 순서.
///
/// `rawValue` 는 사람이 고른 것을 저장하는 데 쓴다. 이름을 바꾸면 저장된 선택이 풀린다.
enum CatalogSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case rating
    case reviewCount
    /// 스토어에 처음 등록된 순서. 새로 생긴 앱을 찾을 때 쓴다.
    case newest
    /// 가장 최근에 새 버전이 나온 순서. 업데이트가 나온 앱을 찾을 때 쓴다.
    case recentlyUpdated

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "이름순"
        case .rating: "별점순"
        case .reviewCount: "리뷰 많은 순"
        case .newest: "최신 등록순"
        case .recentlyUpdated: "최근 업데이트순"
        }
    }

    /// 이 순서로 늘어놓는다.
    ///
    /// **값이 같으면 이름순으로 가른다.** 가르지 않으면 새로 고칠 때마다 같은 값끼리
    /// 자리가 바뀌어, 보던 앱이 목록에서 움직인다.
    ///
    /// 별점이 없는 앱은 별점순과 리뷰 많은 순에서 맨 뒤로 보낸다. 0점으로 치면 별점 1점을
    /// 받은 앱보다도 뒤라는 뜻이 되는데, 받은 적이 없는 것과 나쁜 평을 받은 것은 다르다.
    func sorted(_ apps: [AppDTO]) -> [AppDTO] {
        apps.sorted { lhs, rhs in
            switch compare(lhs, rhs) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: Self.byName(lhs, rhs) == .orderedAscending
            }
        }
    }

    private func compare(_ lhs: AppDTO, _ rhs: AppDTO) -> ComparisonResult {
        switch self {
        case .name:
            return Self.byName(lhs, rhs)
        case .rating:
            return Self.descending(lhs.rating?.average, rhs.rating?.average)
        case .reviewCount:
            return Self.descending(Self.ratedCount(lhs), Self.ratedCount(rhs))
        case .newest:
            return Self.descending(lhs.createdAt, rhs.createdAt)
        case .recentlyUpdated:
            return Self.descending(Self.lastReleased(lhs), Self.lastReleased(rhs))
        }
    }

    /// 가나다·알파벳 순. 숫자는 값으로 견준다 ("앱 2" 가 "앱 10" 앞).
    private static func byName(_ lhs: AppDTO, _ rhs: AppDTO) -> ComparisonResult {
        lhs.name.localizedStandardCompare(rhs.name)
    }

    /// 큰 것이 먼저. 값이 없는 쪽은 뒤로 간다.
    private static func descending<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (l?, r?): l == r ? .orderedSame : (l > r ? .orderedAscending : .orderedDescending)
        case (.some, nil): .orderedAscending
        case (nil, .some): .orderedDescending
        case (nil, nil): .orderedSame
        }
    }

    /// 별점이 하나도 없으면 nil. 0 으로 두면 별점순과 같은 규칙을 지킬 수 없다.
    private static func ratedCount(_ app: AppDTO) -> Int? {
        guard let count = app.rating?.count, count > 0 else { return nil }
        return count
    }

    /// 출시 시각이 없는 예전 버전이면 등록 시각으로 대신한다.
    private static func lastReleased(_ app: AppDTO) -> Date? {
        guard let version = app.latestReleasedVersion else { return nil }
        return version.releasedAt ?? version.createdAt
    }
}
