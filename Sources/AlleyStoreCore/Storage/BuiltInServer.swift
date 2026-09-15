import Foundation

/// 번들에 박혀 나온 서버 주소.
///
/// 소스에는 주소가 없다. 조립 스크립트가 `ALLEY_STORE_APP_SERVER_URL` 을 받아 `Info.plist`
/// 에 넣고, 여기서 그것을 읽는다. 제품 레포는 여전히 어느 조직도 모른다
/// (ADR-0003, ADR-0044).
///
/// 값을 코드가 아니라 `Info.plist` 에 두는 이유는 그 파일이 서명 대상 안에 있기
/// 때문이다. 받은 사람이 주소를 고쳐 다른 서버에 붙이려 하면 서명이 깨진다.
enum BuiltInServer {
    /// `Info.plist` 에서 주소를 찾는 키.
    static let infoKey = "AlleyServerURL"

    /// 이 빌드가 아는 서버. 주소 없이 만든 빌드에서는 nil 이고, 그때는 사람이 넣는다.
    static let url: URL? = resolve(Bundle.main.object(forInfoDictionaryKey: infoKey))

    /// `Info.plist` 값에서 쓸 수 있는 주소만 남긴다.
    ///
    /// 주소를 주지 않은 빌드도 키 자체는 빈 문자열로 남을 수 있다. 빈 값과 없는 값을
    /// 같게 다뤄야 "주소 없는 빌드" 가 한 가지 모양으로 굴러간다.
    static func resolve(_ rawValue: Any?) -> URL? {
        guard let text = rawValue as? String else { return nil }
        return StoreClient.normalize(serverAddress: text)
    }
}
