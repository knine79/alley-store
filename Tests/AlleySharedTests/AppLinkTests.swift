import Foundation
import Testing

@testable import AlleyShared

/// 서버가 만들고 스토어 앱이 읽는 공유 주소 (ADR-0072).
@Suite("앱 공유 주소")
struct AppLinkTests {
    private let appID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test("서버가 만든 스킴 주소를 스토어 앱이 그대로 읽는다")
    func roundTrip() throws {
        let url = try #require(AppLink.storeAppURL(scheme: "alleystore", appID: appID))
        #expect(url.absoluteString == "alleystore://apps/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(AppLink.appID(from: url) == appID)
    }

    @Test("웹 경로는 짧은 소문자 꼴이다")
    func webPath() {
        #expect(AppLink.webPath(appID: appID) == "/a/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    }

    /// 로그인 콜백도 같은 스킴으로 온다. 그것을 앱 링크로 읽으면 안 된다.
    @Test("앱 링크가 아닌 주소는 nil 이다", arguments: [
        "alleystore://auth?code=abc",
        "alleystore://apps/",
        "alleystore://apps/not-a-uuid",
        "alleystore://apps/3f2504e0-4f89-11d3-9a0c-0305e82c3301/extra",
        "alleystore://other/3f2504e0-4f89-11d3-9a0c-0305e82c3301",
    ])
    func rejectsOtherURLs(raw: String) throws {
        #expect(AppLink.appID(from: try #require(URL(string: raw))) == nil)
    }

    @Test("대문자 ID 도 읽는다")
    func acceptsUppercase() throws {
        let url = try #require(URL(string: "alleystore://APPS/3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        #expect(AppLink.appID(from: url) == appID)
    }
}
