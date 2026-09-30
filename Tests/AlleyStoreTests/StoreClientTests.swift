import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

@Suite("서버 주소 다듬기")
struct ServerAddressTests {
    @Test("스킴이 없으면 https 를 붙인다")
    func addsScheme() {
        // 대부분 store.example.com 처럼 적는다. 그대로 URL 로 만들면 경로로 해석된다.
        #expect(
            StoreClient.normalize(serverAddress: "store.example.com")?.absoluteString
                == "https://store.example.com"
        )
    }

    @Test("적어준 스킴은 그대로 둔다")
    func keepsExplicitScheme() {
        // 사내에서 평문으로 띄우는 경우가 있다. 직접 적었다면 그 뜻을 존중한다.
        #expect(
            StoreClient.normalize(serverAddress: "http://localhost:8080")?.absoluteString
                == "http://localhost:8080"
        )
    }

    @Test("뒤에 붙은 슬래시를 떼어낸다")
    func trimsTrailingSlash() {
        // 남겨두면 경로를 조립할 때 //api/v1 이 된다.
        #expect(
            StoreClient.normalize(serverAddress: "https://store.example.com/")?.absoluteString
                == "https://store.example.com"
        )
    }

    @Test("앞뒤 공백을 무시한다")
    func trimsWhitespace() {
        #expect(
            StoreClient.normalize(serverAddress: "  store.example.com  ")?.absoluteString
                == "https://store.example.com"
        )
    }

    @Test("주소로 볼 수 없는 것은 거절한다", arguments: [
        "", "   ", "ftp://store.example.com", "https://",
    ])
    func rejectsNonAddresses(_ raw: String) {
        #expect(StoreClient.normalize(serverAddress: raw) == nil)
    }
}

@Suite("아이콘 주소")
struct IconURLResolvingTests {
    private func app(icon: String?) -> AppDTO {
        AppDTO(
            id: UUID(), bundleID: "com.example.notes", name: "메모장", iconURL: icon,
            ownerID: UUID(), createdAt: Date(), updatedAt: Date()
        )
    }

    @Test("상대 주소는 서버 주소에 붙인다")
    func resolvesRelative() {
        // 예전 서버는 `/apps/<id>/icon.png` 를 그대로 준다. 그대로 쓰면 그림이 안 나온다.
        let server = URL(string: "https://store.example.com")!
        #expect(StoreModel.resolvingIcon(app(icon: "/apps/x/icon.png?v=1"), against: server).iconURL
            == "https://store.example.com/apps/x/icon.png?v=1")
    }

    @Test("절대 주소와 빈 값은 그대로 둔다")
    func keepsAbsolute() {
        let server = URL(string: "https://store.example.com")!
        #expect(StoreModel.resolvingIcon(app(icon: "https://cdn.example.com/a.png"), against: server).iconURL
            == "https://cdn.example.com/a.png")
        #expect(StoreModel.resolvingIcon(app(icon: nil), against: server).iconURL == nil)
    }
}

