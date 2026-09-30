import Foundation
import OSLog
import Security

/// 이 맥에 남는 것들.
///
/// 서버 주소는 비밀이 아니라서 `UserDefaults` 에 둔다. 세션 토큰은 그 자체가 신원이라
/// 키체인에 넣는다. `UserDefaults` 는 평문 plist 파일이고, 다른 앱도 읽을 수 있는 자리다.
struct Credentials {
    /// 키체인 항목을 구분하는 서비스 이름.
    ///
    /// 서버 주소를 함께 넣는다. 서버를 바꿔가며 쓰는 사람이 있을 때 토큰이 섞이지
    /// 않아야 한다.
    private static let service = "Alley Store"
    private static let serverKey = "alley.serverURL"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 서버 주소

    var serverURL: URL? {
        get { defaults.string(forKey: Self.serverKey).flatMap(URL.init(string:)) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.absoluteString, forKey: Self.serverKey)
            } else {
                defaults.removeObject(forKey: Self.serverKey)
            }
        }
    }

    // MARK: - 세션 토큰

    func token(for server: URL) -> String? {
        var query = baseQuery(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Self.log.error("키체인에서 토큰을 읽지 못했습니다: \(Self.describe(status), privacy: .public)")
            }
            return nil
        }
        // 지우지 못한 항목에 남겨둔 로그아웃 표시다 (`setToken`).
        guard data != Self.signedOutMarker else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 토큰을 바꾼다. nil 이면 로그아웃이다.
    ///
    /// **지우고 다시 넣지 않고 값만 바꾼다.** 이 항목은 로그인 키체인(파일 기반)에
    /// 있어서, 지우는 것은 항목을 만든 빌드만 할 수 있다. 업데이트된 앱은 서명 요건이
    /// 같아 읽고 값을 바꿀 수는 있지만 지우면 `errSecInvalidOwnerEdit` 를 받는다.
    /// 예전에는 지우고 넣었다. 지우기가 실패하면 넣기도 "이미 있음" 으로 실패했고, 둘 다
    /// 결과를 버렸다. 로그인은 메모리에만 남았고, 앱을 다시 켜면(업데이트가 그렇다)
    /// 처음 설치한 빌드가 넣어둔 만료된 토큰을 읽어 로그아웃됐다.
    func setToken(_ token: String?, for server: URL) {
        let query = baseQuery(for: server)

        guard let token else {
            let deleted = SecItemDelete(query as CFDictionary)
            guard deleted == errSecInvalidOwnerEdit else {
                if deleted != errSecSuccess, deleted != errSecItemNotFound {
                    Self.log.error("키체인의 토큰을 지우지 못했습니다: \(Self.describe(deleted), privacy: .public)")
                }
                return
            }
            // 지울 수 없으면 표시 값으로 덮는다. 읽을 때 토큰이 없는 것으로 본다.
            update(query, to: Self.signedOutMarker)
            return
        }

        let value = Data(token.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = value
            // 이 맥에서만, 잠금 해제된 뒤에만 읽힌다. 다른 기기로 동기화되지 않는다.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            if added != errSecSuccess {
                Self.log.error("키체인에 토큰을 넣지 못했습니다: \(Self.describe(added), privacy: .public)")
            }
        default:
            Self.log.error("키체인의 토큰을 바꾸지 못했습니다: \(Self.describe(updated), privacy: .public)")
        }
    }

    /// 로그아웃했다는 표시.
    ///
    /// **빈 값으로 비우지 않는다.** 파일 기반 키체인은 빈 값으로 바꾸라는 요청에 성공을
    /// 돌려주고 값은 그대로 둔다. 토큰은 JWT 라 이 값과 겹치지 않는다.
    static let signedOutMarker = Data("signed-out".utf8)

    private func update(_ query: [String: Any], to value: Data) {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status != errSecSuccess {
            Self.log.error("키체인의 토큰을 비우지 못했습니다: \(Self.describe(status), privacy: .public)")
        }
    }

    /// 실패를 버리지 않는다. 키체인이 조용히 실패하면 사람에게는 "로그인이 자꾸 풀린다"
    /// 로만 보이고, 원인은 어디에도 남지 않는다. 이번이 그랬다.
    ///
    /// subsystem 은 번들 ID 다. 조직마다 빌드할 때 들어가는 값이라 여기 적지 않는다.
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "alley-store",
        category: "credentials"
    )

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
        return "\(status) \(message)"
    }

    private func baseQuery(for server: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: server.absoluteString,
        ]
    }
}
