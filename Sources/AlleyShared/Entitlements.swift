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

    /// 프로비저닝 프로필이 있어야 쓸 수 있는 권한인지.
    ///
    /// `com.apple.developer.` 로 시작하는 것들은 Apple 이 팀 단위로 허가하는 기능이라,
    /// 그 허가를 담은 프로필이 번들 안에 들어 있어야 한다. `com.apple.security.` 로
    /// 시작하는 샌드박스·하드닝 권한은 프로필 없이도 서명된다.
    ///
    /// **서명하는 쪽과 화면이 같은 기준을 써야 해서 여기 둔다.** 워커는 이것으로
    /// 서명을 멈출지 정하고(`Entitlements.validate`), 콘솔은 이것으로 포털에 App ID 를
    /// 등록하라고 권할지 정한다. 기준이 갈리면 "서명은 막혔는데 화면은 아무 말도
    /// 안 하는" 자리가 생긴다.
    public static func requiresProvisioningProfile(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.")
    }

    public static func requiringProvisioningProfile(
        in keys: some Sequence<String>
    ) -> [String] {
        keys.filter(requiresProvisioningProfile).sorted()
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
    ///
    /// **없을 수도 있다고 먼저 말한다.** 예전 문구는 "빌드 설정에 이미 있습니다" 로
    /// 시작해서, 없는 사람은 한참 찾다가 막혔다. 애드혹 서명으로 개발하던 앱에는
    /// 만들 이유가 없었고, 그런 앱이 실제로 올라온다.
    ///
    /// **"빌드 설정에" 가 아니라 "프로젝트에" 다.** 빌드가 내놓는 것으로 읽혀서
    /// 결과물 폴더를 뒤지게 만들었다. 사람이 만들어 레포에 두는 파일이다.
    ///
    /// 갈래가 둘이면 갈래를 문장 앞에 세운다. "Xcode 는 A 이고 electron-builder 는
    /// B 입니다" 는 둘 다 읽어야 내 것을 고를 수 있다.
    public static let whereToFind = """
        프로젝트에 이미 있을 수 있습니다. Xcode 로 빌드한 경우는 CODE_SIGN_ENTITLEMENTS \
        가 가리키는 .entitlements 파일이고, electron-builder 로 빌드한 경우는 보통 \
        build/entitlements.mac.plist 입니다. 없으면 새로 만들어도 됩니다. 파일 이름은 \
        아무거나 되고 확장자만 .plist 나 .entitlements 면 됩니다.
        """

    /// 왜 내 맥에서는 되는데 여기서는 안 되나.
    ///
    /// 이 한 줄이 없으면 "실행되자마자 죽습니다" 가 오진처럼 읽힌다. 멀쩡히 쓰고 있던
    /// 앱이라 더 그렇다.
    public static let whyItWorksLocally = """
        개발 중에는 Hardened Runtime 없이 서명되어 이 권한이 필요 없었을 수 있습니다. \
        스토어 배포는 공증이 필요하고, 공증은 Hardened Runtime 을 요구합니다.
        """

    /// CLI 로 붙이는 법.
    ///
    /// **웹 콘솔에는 이런 문장을 두지 않는다.** 예전에는 "이 실패 바로 아래
    /// 'entitlements' 칸에 파일을 넣고 '붙여서 다시 시도' 를 누르세요" 를 함께 냈는데,
    /// 그 칸과 그 버튼이 바로 아래 보이는 자리에서 읽는 말이라 군말이었다. 화면은
    /// 칸과 버튼으로 말하고, 글로 하는 안내는 화면이 없는 CLI 쪽에만 남긴다.
    public static let howToSendWithCLI = """
        CLI 로 올린다면 `alley upload ... --entitlements build/app.entitlements` 입니다.
        """

    /// Electron 앱이 Hardened Runtime 아래에서 돌기 위한 최소 entitlements.
    ///
    /// electron-builder 가 기본으로 넣는 네 키와 같다. 파일이 아예 없는 사람에게 키
    /// 이름 하나만 알려주면 XML 뼈대부터 막힌다. 그래서 그대로 복사해 쓸 수 있는 전문을
    /// 준다.
    ///
    /// **이것은 최소값이지 정답이 아니다.** 카메라·마이크처럼 더 쓰는 권한이 있으면 키가
    /// 더 필요하고, 그때는 서명과 공증은 통과하는데 그 기능만 조용히 안 된다.
    public static let electronTemplate = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>com.apple.security.cs.allow-jit</key>
        \t<true/>
        \t<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
        \t<true/>
        \t<key>com.apple.security.cs.allow-dyld-environment-variables</key>
        \t<true/>
        \t<key>com.apple.security.cs.disable-library-validation</key>
        \t<true/>
        </dict>
        </plist>
        """

    /// 본보기 앞에 세우는 한 줄. **이것이 무엇이고 무엇을 하면 되는지**를 말한다.
    ///
    /// 예전 문구는 "electron-builder 의 기본값입니다" 로 시작해서, 이 덩어리를 왜
    /// 보여주는지가 드러나지 않았다. 그 다음에 붙은 "프로젝트에 이미 있으면 그쪽이
    /// 정확합니다" 는 `whereToFind` 가 이미 한 말이라 뺐다.
    public static let electronTemplateNotes = """
        아래를 그대로 복사해 .entitlements 파일로 저장하면 됩니다. \
        electron-builder 가 기본으로 넣는 네 키입니다.
        """

    /// 본보기 뒤에 붙는 한 줄. 그대로 쓰면 안 되는 경우를 말한다.
    ///
    /// 앞이 아니라 뒤에 두는 이유는, 복사할 것을 먼저 주고 단서를 나중에 다는 것이
    /// 읽는 순서이기 때문이다.
    public static let electronTemplateCaveat = """
        앱이 카메라나 마이크를 사용한다면, 해당 키를 추가해야 하고, 빠뜨리면 서명과 \
        공증은 통과하지만 해당 기능만 동작하지 않게 됩니다.
        """

    /// Electron 을 품었는데 JIT 권한이 없을 때.
    ///
    /// 이대로 서명하면 공증은 통과하고 실행만 안 되는 앱이 나간다. 그래서 서명 전에 멈춘다.
    ///
    /// **원인만 적는다.** 예전에는 여기에 어디서 찾는지·콘솔에서 어떻게 붙이는지·CLI
    /// 로는 어떻게 하는지까지 넣었다. 그 문장들이 화면에서 한 번 더 나와서, 실패한
    /// 사람이 같은 말을 두 번 읽고 정작 무엇이 걸렸는지는 못 찾았다. 붙이는 법은
    /// 붙이는 칸 옆에서 말하는 것이 맞다.
    public static func missingJIT(bundle: String) -> String {
        """
        \(bundle) 안에 Electron Framework 가 있는데 entitlements 에 \(jitKey) 가 없습니다. \
        이 권한 없이 서명하면 공증은 통과하지만 앱이 실행되자마자 죽습니다.
        """
    }

    /// entitlements 없이 서명했을 때 잡 로그에 남기는 한 줄.
    ///
    /// 실패시키지 않는다. 네이티브 맥 앱은 대부분 정말로 필요 없다.
    ///
    /// **여기서는 콘솔의 붙이는 칸을 가리키지 않는다.** 그 칸은 실패한 버전 옆에만
    /// 나온다. 이 줄이 남는 잡은 서명에 성공했으므로 붙일 자리가 없다. 필요하다면
    /// entitlements 를 갖춰 다시 올리는 것이 길이다.
    public static let noneProvided = """
        entitlements 없이 서명했습니다. \(whenNeeded) 설치는 되는데 실행하자마자 죽는다면 \
        이것을 먼저 의심하고, entitlements 를 붙여 새 버전을 올리세요. \(howToSendWithCLI)
        """
}
