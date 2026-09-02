import Foundation
import Testing

@testable import AlleyShared

/// 업로더가 준 entitlements 를 **받는 자리에서** 걸러내는지.
///
/// 서명할 때가 되어서야 깨진 plist 를 발견하면 왕복이 길다. 그때는 워커가 이미 잡을
/// 물고 있고, 올린 사람은 몇 분 뒤에야 실패를 본다.
@Suite("entitlements plist 검사")
struct EntitlementsPlistTests {
    private let valid = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.cs.allow-jit</key>
            <true/>
            <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
            <true/>
        </dict>
        </plist>
        """

    @Test("제대로 된 plist 에서 키를 뽑는다")
    func readsKeys() throws {
        let keys = try EntitlementsPlist.validate(valid)
        #expect(keys == [
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory",
        ])
    }

    @Test("plist 가 아니면 거절한다")
    func rejectsGarbage() {
        #expect(throws: EntitlementsPlist.PlistError.notAPropertyList) {
            try EntitlementsPlist.validate("이건 plist 가 아닙니다")
        }
    }

    @Test("최상위가 사전이 아니면 거절한다")
    func rejectsNonDictionaryRoot() {
        // 배열이 최상위인 plist 는 문법상 멀쩡하지만 codesign 이 받지 않는다.
        let array = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><array><string>하나</string></array></plist>
            """
        #expect(throws: EntitlementsPlist.PlistError.notADictionary) {
            try EntitlementsPlist.validate(array)
        }
    }

    @Test("너무 크면 거절한다")
    func rejectsOversized() {
        // 상한을 넘겼다면 대개 entitlements 가 아닌 다른 파일을 고른 것이다.
        let padding = String(repeating: "가", count: EntitlementsPlist.maximumSize)
        #expect(throws: (any Error).self) {
            try EntitlementsPlist.validate(padding)
        }
    }

    @Test("키만 뽑을 때는 못 읽어도 던지지 않는다")
    func keysNeverThrow() {
        // 화면에 "무엇으로 서명했나"를 그리는 자리에서 쓴다. 형식은 받을 때 이미 봤다.
        #expect(EntitlementsPlist.keys(of: "쓰레기").isEmpty)
        #expect(EntitlementsPlist.keys(of: valid).count == 2)
    }
}
