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

/// 관리자가 화면에서 바꿀 수 있는 설정 전체.
///
/// `StoreMeta` 는 로그인 전 누구나 볼 수 있는 공개 정보이고, 이쪽은 관리자만 본다.
/// 번들 ID 정책처럼 밖에 알릴 필요가 없는 항목이 섞여 있어서 타입을 나눈다.
public struct StoreSettingsDTO: Codable, Sendable, Equatable {
    public var storeName: String
    public var logoURL: String?
    public var accentColor: String?
    public var allowedEmailDomains: [String]
    public var bundleIDPrefix: String?
    public var enforceBundleIDPrefix: Bool
    public var updatedAt: Date?

    public init(
        storeName: String,
        logoURL: String? = nil,
        accentColor: String? = nil,
        allowedEmailDomains: [String] = [],
        bundleIDPrefix: String? = nil,
        enforceBundleIDPrefix: Bool = true,
        updatedAt: Date? = nil
    ) {
        self.storeName = storeName
        self.logoURL = logoURL
        self.accentColor = accentColor
        self.allowedEmailDomains = allowedEmailDomains
        self.bundleIDPrefix = bundleIDPrefix
        self.enforceBundleIDPrefix = enforceBundleIDPrefix
        self.updatedAt = updatedAt
    }
}

/// 설정 변경 요청.
///
/// 모든 항목이 옵셔널이다. 보낸 항목만 바꾸고 안 보낸 항목은 건드리지 않는다.
/// 화면에서 한 칸만 고쳤는데 나머지가 통째로 덮어써지면 곤란하다.
public struct UpdateStoreSettingsRequest: Codable, Sendable {
    public var storeName: String?
    public var logoURL: String?
    public var accentColor: String?
    public var allowedEmailDomains: [String]?
    public var bundleIDPrefix: String?
    public var enforceBundleIDPrefix: Bool?

    /// 로그인 허용 도메인을 비우려면 이 값을 명시적으로 켜야 한다.
    ///
    /// 목록이 비면 조직 밖 계정도 전부 로그인할 수 있다. 오타 한 번으로 그렇게 되는
    /// 것과, 그렇게 하겠다고 한 번 더 말하는 것은 다르다.
    public var confirmOpenToAnyDomain: Bool?

    public init(
        storeName: String? = nil,
        logoURL: String? = nil,
        accentColor: String? = nil,
        allowedEmailDomains: [String]? = nil,
        bundleIDPrefix: String? = nil,
        enforceBundleIDPrefix: Bool? = nil,
        confirmOpenToAnyDomain: Bool? = nil
    ) {
        self.storeName = storeName
        self.logoURL = logoURL
        self.accentColor = accentColor
        self.allowedEmailDomains = allowedEmailDomains
        self.bundleIDPrefix = bundleIDPrefix
        self.enforceBundleIDPrefix = enforceBundleIDPrefix
        self.confirmOpenToAnyDomain = confirmOpenToAnyDomain
    }
}
