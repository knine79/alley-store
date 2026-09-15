import Foundation
import Testing

@testable import AlleyStoreCore

@Suite("번들에 박힌 서버 주소")
struct BuiltInServerTests {
    @Test("박힌 주소를 읽는다")
    func readsInjectedAddress() {
        #expect(
            BuiltInServer.resolve("https://store.example.com")?.absoluteString
                == "https://store.example.com"
        )
    }

    @Test("주소를 주지 않은 빌드는 nil 이다", arguments: [nil, "", "   "] as [String?])
    func noAddress(_ raw: String?) {
        // 키가 아예 없는 빌드와 빈 문자열로 남은 빌드가 같아야 한다. 다르면 "주소 없는
        // 빌드" 가 두 가지 모양이 되고, 화면이 그중 하나만 다루게 된다.
        #expect(BuiltInServer.resolve(raw) == nil)
    }

    @Test("문자열이 아닌 값은 무시한다")
    func ignoresNonString() {
        // plist 는 숫자나 배열도 담을 수 있다. 잘못 들어간 값에 앱이 넘어가지 않는다.
        #expect(BuiltInServer.resolve(42) == nil)
    }

    @Test("주소로 볼 수 없는 값은 무시한다")
    func ignoresMalformed() {
        // 스크립트가 먼저 막지만, 손으로 만든 plist 도 있을 수 있다.
        #expect(BuiltInServer.resolve("ftp://store.example.com") == nil)
    }
}

@Suite("주소가 박힌 빌드의 상태")
@MainActor
struct BuiltInServerModelTests {
    @Test("서버를 잊으라는 요청을 받아도 그대로 있는다")
    func keepsBuiltInServer() {
        // 주소 입력 화면으로 돌아가면 그 빌드는 거기서 나올 길이 없다.
        let model = StoreModel(builtInServer: URL(string: "https://store.example.com"))
        model.forgetServer()
        #expect(model.builtInServer != nil)
    }
}
