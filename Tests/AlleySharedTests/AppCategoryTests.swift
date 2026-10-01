import Testing

@testable import AlleyShared

@Suite("앱 분류")
struct AppCategoryTests {
    @Test("저장된 값과 화면 이름을 모두 읽는다")
    func readsStoredAndTitle() {
        #expect(AppCategory(stored: "developer-tools") == .developerTools)
        // 목록을 고정하기 전에 사람이 적은 값.
        #expect(AppCategory(stored: " 개발 도구 ") == .developerTools)
    }

    @Test("모르는 값과 빈 값은 미분류")
    func unknownIsUncategorized() {
        #expect(AppCategory(stored: "개발도구") == nil)
        #expect(AppCategory(stored: "") == nil)
        #expect(AppCategory(stored: nil) == nil)
    }

    @Test("저장 값은 바뀌지 않는다")
    func rawValuesAreStable() {
        // 데이터베이스와 API 에 이 값이 들어간다. 바꾸면 저장된 분류가 풀린다.
        #expect(AppCategory.allCases.map(\.rawValue) == [
            "developer-tools", "business", "productivity", "communication",
            "design", "utilities", "data-analytics", "other",
        ])
    }
}
