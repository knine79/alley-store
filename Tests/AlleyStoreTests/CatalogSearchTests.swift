import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

@Suite("앱 검색")
struct CatalogSearchTests {
    private func app(
        _ name: String,
        summary: String? = nil,
        description: String? = nil,
        tags: [String]? = nil,
        developers: [String]? = nil
    ) -> AppDTO {
        AppDTO(
            id: UUID(), bundleID: "com.example.\(UUID().uuidString.prefix(6))", name: name,
            summary: summary, description: description, tags: tags, ownerID: UUID(),
            developerNames: developers, createdAt: Date(), updatedAt: Date()
        )
    }

    private func names(_ apps: [AppDTO], _ query: String) -> [String] {
        CatalogSearch.filter(apps, query: query).map(\.name)
    }

    @Test("이름 말고도 태그, 개발자, 소개, 설명에서 찾는다")
    func searchesAllFields() {
        let apps = [
            app("메모장", tags: ["노트"]),
            app("일정", developers: ["김노트"]),
            app("번역기", summary: "노트를 번역합니다"),
            app("계산기", description: "노트와 상관없음"),
            app("시계"),
        ]
        #expect(Set(names(apps, "노트")) == ["메모장", "일정", "번역기", "계산기"])
    }

    @Test("이름이 맞는 앱이 먼저, 그다음 태그, 개발자, 설명 순이다")
    func ranksByWhereItMatched() {
        let apps = [
            app("설명", description: "git 클라이언트"),
            app("개발자", developers: ["git 담당"]),
            app("태그", tags: ["Git"]),
            app("GitBar"),
        ]
        #expect(names(apps, "git") == ["GitBar", "태그", "개발자", "설명"])
    }

    @Test("같은 자리에 걸린 것끼리는 받은 순서를 지킨다")
    func keepsChosenOrderWithinRank() {
        // 받은 순서는 사람이 고른 정렬이다. 검색이 그것을 흩뜨리면 안 된다.
        let apps = [app("나 노트"), app("가 노트"), app("다 노트")]
        #expect(names(apps, "노트") == ["나 노트", "가 노트", "다 노트"])
    }

    @Test("대소문자를 가리지 않고, 빈 검색어는 전부 돌려준다")
    func caseInsensitiveAndEmpty() {
        let apps = [app("Alpha", tags: ["Translate"]), app("Beta")]
        #expect(names(apps, "TRANSLATE") == ["Alpha"])
        #expect(names(apps, "  ") == ["Alpha", "Beta"])
    }

    @Test("태그를 모르는 예전 서버의 앱도 찾는다")
    func handlesMissingTags() {
        #expect(names([app("메모장", tags: nil)], "메모") == ["메모장"])
    }
}
