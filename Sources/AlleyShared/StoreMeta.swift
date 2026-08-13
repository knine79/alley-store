import Foundation

/// 클라이언트가 서버 도메인만 알고 부트스트랩할 때 받아가는 스토어 정보.
///
/// 스토어 이름, 로고, 색상 같은 브랜딩 값은 전부 서버가 내려준다.
/// 클라이언트 바이너리에는 어떤 조직 고유값도 들어가지 않는다.
public struct StoreMeta: Codable, Sendable, Equatable {
    /// UI에 노출되는 스토어 이름.
    public var storeName: String
    /// 로고 이미지 URL. 없으면 클라이언트가 기본 심볼을 쓴다.
    public var logoURL: String?
    /// 강조 색상 (`#RRGGBB`). 없으면 클라이언트 기본값.
    public var accentColor: String?
    /// 로그인 화면에 안내할 허용 도메인 목록. 실제 검증은 서버가 한다.
    public var allowedEmailDomains: [String]
    /// OAuth 시작 경로. 클라이언트가 여기로 웹 인증 세션을 연다.
    public var authorizationPath: String
    /// 스토어 앱이 인증 콜백을 받을 커스텀 URL 스킴.
    public var callbackURLScheme: String
    /// 서버가 지원하는 API 버전. 클라이언트 호환성 판단에 쓴다.
    public var apiVersion: Int

    public init(
        storeName: String,
        logoURL: String? = nil,
        accentColor: String? = nil,
        allowedEmailDomains: [String] = [],
        authorizationPath: String = APIPath.googleAuthorize,
        callbackURLScheme: String,
        apiVersion: Int = APIPath.currentAPIVersion
    ) {
        self.storeName = storeName
        self.logoURL = logoURL
        self.accentColor = accentColor
        self.allowedEmailDomains = allowedEmailDomains
        self.authorizationPath = authorizationPath
        self.callbackURLScheme = callbackURLScheme
        self.apiVersion = apiVersion
    }
}
