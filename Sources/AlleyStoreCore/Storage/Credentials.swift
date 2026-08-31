import Foundation
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
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String?, for server: URL) {
        // 갱신은 지우고 다시 넣는다. SecItemUpdate 는 항목이 없을 때를 따로 다뤄야 해서
        // 경우의 수만 늘어난다.
        SecItemDelete(baseQuery(for: server) as CFDictionary)
        guard let token else { return }

        var attributes = baseQuery(for: server)
        attributes[kSecValueData as String] = Data(token.utf8)
        // 이 맥에서만, 잠금 해제된 뒤에만 읽힌다. 다른 기기로 동기화되지 않는다.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(for server: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: server.absoluteString,
        ]
    }
}
