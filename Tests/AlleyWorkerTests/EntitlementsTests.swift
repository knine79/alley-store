import Foundation
import Testing

@testable import AlleyWorkerCore

@Suite("권한 판정")
struct EntitlementsTests {
    @Test("프로필이 필요한 권한을 알아본다", arguments: [
        "com.apple.developer.icloud-services",
        "com.apple.developer.networking.networkextension",
        "com.apple.developer.applesignin",
    ])
    func recognizesRestricted(_ key: String) {
        #expect(Entitlements.isRestricted(key))
    }

    @Test("프로필 없이 서명할 수 있는 권한은 통과시킨다", arguments: [
        "com.apple.security.cs.allow-jit",
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
    ])
    func allowsUnrestricted(_ key: String) {
        // 샌드박스·하드닝 관련 권한은 팀 허가가 필요 없다.
        #expect(!Entitlements.isRestricted(key))
    }

    @Test("plist 에서 키를 뽑는다")
    func readsKeysFromPropertyList() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.security.cs.allow-jit</key>
                <true/>
                <key>com.apple.developer.icloud-services</key>
                <array><string>CloudKit</string></array>
            </dict>
            </plist>
            """

        let keys = Entitlements.keys(fromPropertyList: Data(plist.utf8))
        #expect(keys == ["com.apple.developer.icloud-services", "com.apple.security.cs.allow-jit"])
    }

    @Test("서명이 없는 번들은 권한이 없는 것으로 본다")
    func emptyOutputMeansNoEntitlements() {
        // codesign 이 아무것도 못 읽으면 빈 출력이 온다. 권한을 안 쓰는 앱이 대부분이다.
        #expect(Entitlements.keys(fromPropertyList: Data()).isEmpty)
        #expect(Entitlements.keys(fromPropertyList: Data("쓰레기".utf8)).isEmpty)
    }

    @Test("프로필이 필요한 권한인데 프로필이 없으면 막는다")
    func blocksMissingProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")

        // 그대로 서명하면 앱은 실행되는데 그 기능만 조용히 죽는다.
        #expect(throws: Entitlements.ValidationError.self) {
            try Entitlements.validate(
                bundle: app,
                declaredKeys: ["com.apple.developer.icloud-services"]
            )
        }
    }

    @Test("프로필이 들어 있으면 통과한다")
    func passesWithProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeFile("도구.app/Contents/embedded.provisionprofile", contents: "프로필")

        try Entitlements.validate(
            bundle: app,
            declaredKeys: ["com.apple.developer.icloud-services"]
        )
    }

    @Test("프로필이 필요 없는 권한만 쓰면 프로필 없이 통과한다")
    func passesWithoutRestrictedKeys() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")

        try Entitlements.validate(bundle: app, declaredKeys: ["com.apple.security.cs.allow-jit"])
    }

    @Test("권한이 없으면 파일을 만들지 않는다")
    func writesNothingForEmptyEntitlements() throws {
        let fixture = try BundleFixture()
        let target = fixture.root.appendingPathComponent("entitlements.plist")

        // 빈 --entitlements 파일을 넘기면 codesign 이 오히려 권한을 지운다.
        #expect(Entitlements.writePropertyList(Data(), to: target) == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
