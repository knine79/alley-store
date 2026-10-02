import Testing

@testable import AlleyShared

@Suite("앱 태그 규칙")
struct AppTagsRuleTests {
    @Test("앞뒤 공백을 떼고 빈 것은 버린다")
    func trims() throws {
        #expect(try AppTags.normalize(["  번역 ", "", "   "]) == ["번역"])
    }

    @Test("대소문자만 다른 것은 처음 적은 표기 하나로 합친다")
    func mergesCaseInsensitiveDuplicates() throws {
        #expect(try AppTags.normalize(["Git", "git", "GIT", "일정"]) == ["Git", "일정"])
    }

    @Test("개수를 넘으면 잘라내지 않고 거절한다")
    func rejectsTooMany() throws {
        let tags = (1...AppTags.maximumCount + 1).map { "t\($0)" }
        #expect(throws: AppTags.ValidationError.tooMany(AppTags.maximumCount + 1)) {
            try AppTags.normalize(tags)
        }
        // 중복을 합친 뒤에 센다. 같은 것을 여러 번 적었다고 거절하지 않는다.
        #expect(try AppTags.normalize(Array(repeating: "a", count: 20)) == ["a"])
    }

    @Test("너무 긴 태그는 거절한다")
    func rejectsTooLong() throws {
        let long = String(repeating: "가", count: AppTags.maximumLength + 1)
        #expect(throws: AppTags.ValidationError.tooLong(long)) {
            try AppTags.normalize([long])
        }
        #expect(try AppTags.normalize([String(repeating: "가", count: AppTags.maximumLength)]).count == 1)
    }

    @Test("쉼표나 #으로 나누고, 띄어쓰기는 태그 안에 남긴다")
    func splits() throws {
        #expect(AppTags.split("a, b,,c") == ["a", " b", "c"])
        #expect(try AppTags.normalize(AppTags.split("#일정 관리 #번역")) == ["일정 관리", "번역"])
        #expect(try AppTags.normalize(AppTags.split("#git, #Git ##메모")) == ["git", "메모"])
    }
}
