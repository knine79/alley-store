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

@Suite("붙을 곳은 하나뿐이다")
@MainActor
struct BuiltInServerModelTests {
    /// **서버를 바꾸는 길이 없어야 한다.**
    ///
    /// 예전에는 "다른 서버에 연결" 이 있었고, 주소가 박힌 빌드에서만 그 버튼을
    /// 감췄다. 감추는 것으로는 모자란다. 주소를 묻는 화면이 코드에 남아 있는 한
    /// 어떤 경로로든 거기에 닿을 수 있고, 닿으면 그 앱은 서명한 조직이 보증하지
    /// 않은 서버에도 붙는 앱이 된다.
    ///
    /// 그래서 기능 자체를 걷어냈다. 이 시험은 그것이 다시 생기면 깨진다.
    @Test("모델에 서버를 바꾸는 길이 없다")
    func hasNoWayToSwitchServers() {
        let model = StoreModel(builtInServer: URL(string: "https://store.example.com"))
        #expect(model.builtInServer?.absoluteString == "https://store.example.com")

        // 시작 상태는 "묻는 중" 이 아니라 "붙는 중" 이다. 물어볼 것이 없다.
        #expect(model.phase == .connecting)
    }

    /// 주소 없이 만든 빌드는 물어보지 않고 잘못 만들어졌다고 말한다.
    ///
    /// 물어보면 그 빌드는 어느 조직의 서버에도 붙는다. 사람이 고칠 수 있는 것이
    /// 아니라 빌드가 잘못된 것이므로, 고칠 사람에게 전할 말만 남긴다.
    @Test("주소 없는 빌드는 아무 데도 붙지 않는다")
    func buildWithoutAddressConnectsNowhere() async {
        let model = StoreModel(builtInServer: nil)
        await model.restore()
        #expect(model.phase == .connecting)
    }
}
