import Foundation

/// 앱 태그의 규칙.
///
/// 태그는 "이 낱말로 검색하면 내 앱이 나왔으면" 하는 검색어다. 분류가 아니다.
public enum AppTags {
    /// 앱 하나에 붙일 수 있는 수.
    ///
    /// 검색어를 끝없이 붙이면 아무 검색에나 걸려 검색이 쓸모없어진다.
    public static let maximumCount = 10
    /// 태그 하나의 길이. 문장을 넣을 자리가 아니다. 그건 설명에 쓴다.
    public static let maximumLength = 20

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case tooMany(Int)
        case tooLong(String)

        public var description: String {
            switch self {
            case .tooMany(let count):
                "태그는 \(AppTags.maximumCount)개까지 붙일 수 있습니다. 지금 \(count)개입니다."
            case .tooLong(let tag):
                "태그는 \(AppTags.maximumLength)자까지입니다: \(tag)"
            }
        }
    }

    /// 입력칸에 적은 것을 태그로 나눈다.
    ///
    /// `#번역 #일정` 처럼 `#` 으로 적어도, `번역, 일정` 처럼 쉼표로 적어도 된다. 띄어쓰기는
    /// 나누는 자리가 아니다. `#일정 관리 #번역` 은 "일정 관리" 와 "번역" 이다.
    public static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "#" }).map(String.init)
    }

    /// 저장할 형태로 다듬는다.
    ///
    /// 앞뒤 공백을 떼고 빈 것은 버린다. **대소문자만 다른 것은 하나로 합친다.** 검색은
    /// 대소문자를 가리지 않으므로 "Git" 과 "git" 을 둘 다 두면 자리만 차지한다. 처음
    /// 적은 쪽의 표기를 남긴다.
    ///
    /// 넘치는 것을 조용히 잘라내지 않고 거절한다. 잘라내면 어느 것이 빠졌는지 모른다.
    public static func normalize(_ raw: [String]) throws -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for value in raw {
            // `#` 은 태그임을 보이는 표시일 뿐 이름의 일부가 아니다. 저장하지 않는다.
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .drop { $0 == "#" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            guard tag.count <= maximumLength else { throw ValidationError.tooLong(tag) }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag)
        }
        guard tags.count <= maximumCount else { throw ValidationError.tooMany(tags.count) }
        return tags
    }
}
