import Foundation

/// 업로더가 버전과 함께 올리는 entitlements plist.
///
/// 미서명 업로드에는 읽어낼 기존 서명이 없어서, 그 앱이 무슨 권한을 쓰는지 아는 것은
/// 앱을 만든 사람뿐이다. 그래서 업로더가 직접 준다 (ADR-0020).
///
/// 여기는 형식만 본다. "이 키를 서명해도 되는가"는 프로비저닝 프로필이 번들 안에
/// 있는지에 달렸고, 그건 번들을 손에 쥔 워커만 판단할 수 있다.
public enum EntitlementsPlist {
    /// 받아들이는 최대 크기. 넘으면 거절한다.
    ///
    /// 실제 entitlements 는 1KB 도 되지 않는다. 64KB 를 넘겼다면 대개 다른 파일을
    /// 고른 것이고, 그걸 서명할 때까지 끌고 가면 왕복만 길어진다.
    public static let maximumSize = 64 * 1024

    public enum PlistError: Error, CustomStringConvertible, Equatable {
        case tooLarge(bytes: Int)
        case notAPropertyList
        case notADictionary

        public var description: String {
            switch self {
            case .tooLarge(let bytes):
                return """
                    entitlements 가 너무 큽니다 (\(bytes)바이트). 상한은 \(maximumSize)바이트입니다. \
                    entitlements 는 보통 1KB 도 되지 않으니 다른 파일을 고르지 않았는지 확인하세요.
                    """
            case .notAPropertyList:
                return """
                    entitlements 를 plist 로 읽지 못했습니다. codesign 이 그대로 받는 XML plist 여야 \
                    합니다. \(EntitlementsGuidance.whereToFind)
                    """
            case .notADictionary:
                return """
                    entitlements plist 의 최상위가 사전이 아닙니다. 권한 키와 값을 담은 \
                    <dict> 하나여야 합니다. \(EntitlementsGuidance.whereToFind)
                    """
            }
        }
    }

    /// 형식을 확인하고 최상위 키를 돌려준다.
    ///
    /// **받는 자리에서 바로 부른다.** 서명할 때가 되어서야 깨진 plist 를 발견하면 이미
    /// 워커가 그 잡을 물고 있고, 올린 사람은 한참 뒤에 실패를 본다.
    @discardableResult
    public static func validate(_ xml: String) throws -> [String] {
        let data = Data(xml.utf8)
        guard data.count <= maximumSize else {
            throw PlistError.tooLarge(bytes: data.count)
        }
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) else {
            throw PlistError.notAPropertyList
        }
        guard let dictionary = parsed as? [String: Any] else {
            throw PlistError.notADictionary
        }
        return dictionary.keys.sorted()
    }

    /// 최상위 키만 뽑는다. 읽을 수 없으면 빈 배열이다.
    ///
    /// 화면에 "무엇으로 서명했는가"를 보여주는 쪽에서 쓴다. 그 자리에서 오류를 던져봐야
    /// 할 일이 없다. 형식은 받을 때 이미 확인했다.
    public static func keys(of xml: String) -> [String] {
        (try? validate(xml)) ?? []
    }
}

/// entitlements 를 두고 사람에게 하는 말을 한 군데 모은다.
///
/// 서버·워커·CLI·웹 콘솔이 같은 상황을 각자 다른 문장으로 설명하면, 읽는 사람은 같은
/// 문제를 매번 처음 보는 것처럼 만난다. 문장을 고칠 일이 생겨도 여기 한 곳만 고친다.
public enum EntitlementsGuidance {
    /// Electron 이 Hardened Runtime 아래에서 반드시 필요로 하는 권한.
    public static let jitKey = "com.apple.security.cs.allow-jit"

    /// 이게 무엇이고 언제 필요한지. 화면과 도움말에 그대로 붙인다.
    public static let whenNeeded =
        "대부분의 맥 앱은 필요 없습니다. Electron 처럼 JIT 를 쓰는 런타임을 품은 앱만 필요합니다."

    /// 그 파일을 어디서 얻나.
    public static let whereToFind = """
        파일은 대개 앱 빌드 설정에 이미 있습니다. Xcode 는 CODE_SIGN_ENTITLEMENTS 가 \
        가리키는 .entitlements 파일이고, Electron 은 빌드 스크립트가 codesign 에 넘기는 \
        plist 입니다.
        """

    /// 어디에 넣나.
    public static let howToSend = """
        CLI 는 `alley upload ... --entitlements build/app.entitlements` 로, 웹 콘솔은 \
        새 버전 화면의 'entitlements' 파일 선택으로 함께 올립니다.
        """

    /// Electron 을 품었는데 JIT 권한이 없을 때.
    ///
    /// 이대로 서명하면 공증은 통과하고 실행만 안 되는 앱이 나간다. 그래서 서명 전에 멈춘다.
    public static func missingJIT(bundle: String) -> String {
        """
        \(bundle) 안에 Electron Framework 가 있는데 entitlements 에 \(jitKey) 가 없습니다. \
        Hardened Runtime 아래에서 이 권한 없이 V8 을 띄우면 앱이 실행되자마자 죽습니다. \
        서명해도 공증은 통과하므로 아무도 실행할 수 없는 앱이 그대로 나갑니다. 그래서 여기서 멈춥니다.

        <key>\(jitKey)</key><true/> 를 넣은 entitlements plist 를 버전과 함께 올리세요. \
        \(whereToFind) \(howToSend)
        """
    }

    /// entitlements 없이 서명했을 때 잡 로그에 남기는 한 줄.
    ///
    /// 실패시키지 않는다. 네이티브 맥 앱은 대부분 정말로 필요 없다.
    public static let noneProvided = """
        entitlements 없이 서명했습니다. \(whenNeeded) 설치는 되는데 실행하자마자 죽는다면 \
        이것을 먼저 의심하세요. \(howToSend)
        """
}
