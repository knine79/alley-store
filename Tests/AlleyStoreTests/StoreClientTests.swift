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
