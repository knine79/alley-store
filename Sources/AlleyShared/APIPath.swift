import Foundation

/// 서버·워커·스토어 앱이 공유하는 API 경로 상수.
///
/// 문자열을 각자 하드코딩하면 스펙이 어긋나므로 여기서만 정의한다.
public enum APIPath {
    public static let currentAPIVersion = 1

    public static let apiRoot = "/api/v1"

    // MARK: - 부트스트랩 / 인증

    /// 비인증으로 접근 가능한 스토어 메타 정보.
    public static let meta = "\(apiRoot)/meta"
    /// 헬스체크 (오케스트레이터용).
    public static let health = "/health"

    public static let googleAuthorize = "/auth/google"
    public static let googleCallback = "/auth/google/callback"

    /// 로그인을 시작할 때 어떤 클라이언트인지 알리는 질의 항목.
    ///
    /// 값이 ``appClient`` 면 인증 후 커스텀 URL 스킴으로 돌려보낸다.
    /// 스토어 앱과 서버가 같은 문자열을 봐야 하므로 여기서만 정의한다.
    public static let clientQueryItem = "client"
    public static let appClient = "app"
    /// 스토어 앱이 일회용 코드를 세션 토큰으로 교환하는 경로.
    public static let tokenExchange = "\(apiRoot)/auth/token"
    public static let currentUser = "\(apiRoot)/me"

    // MARK: - 앱 / 버전

    public static let apps = "\(apiRoot)/apps"

    /// 이미 등록된 번들 ID 목록. 새 앱을 만들기 전에 중복을 스스로 확인한다.
    public static let bundleIDs = "\(apiRoot)/bundle-ids"

    public static func app(_ id: UUID) -> String {
        "\(apps)/\(id.uuidString)"
    }

    /// 앱별 업로드 권한자 목록.
    public static func members(ofApp id: UUID) -> String {
        "\(app(id))/members"
    }

    public static func member(ofApp appID: UUID, userID: UUID) -> String {
        "\(members(ofApp: appID))/\(userID.uuidString)"
    }

    /// 앱별 배포 토큰 목록·발급.
    public static func deployTokens(ofApp id: UUID) -> String {
        "\(app(id))/deploy-tokens"
    }

    public static func deployToken(ofApp appID: UUID, tokenID: UUID) -> String {
        "\(deployTokens(ofApp: appID))/\(tokenID.uuidString)"
    }

    /// Sparkle 이 읽는 appcast. 앱별 피드 토큰을 경로에 싣는다 (ADR-0017, ADR-0025).
    ///
    /// 토큰이 경로에 있는 이유는 질의 항목이 액세스 로그에 그대로 남기 때문이다.
    /// 자세한 것은 ADR-0025 에 있다. Sparkle 은 `SUFeedURL` 을 그대로 GET 하므로
    /// 토큰이 경로에 있든 질의에 있든 앱 쪽 코드는 달라지지 않는다.
    public static func appcast(ofApp id: UUID, token: String) -> String {
        "\(app(id))/feed/\(token)/appcast.xml"
    }

    /// 폐기 예정인 옛 피드 주소. 토큰을 ``feedTokenQueryItem`` 질의 항목으로 받는다.
    ///
    /// **새로 발급하는 주소에 쓰지 않는다.** 이미 배포된 앱의 `Info.plist` 에 이
    /// 형식이 박혀 있어서 아직 받아줄 뿐이다. 서버는 이 형식으로 들어온 요청에
    /// `Deprecation` 헤더를 붙이고 로그를 남긴다.
    public static func legacyAppcast(ofApp id: UUID) -> String {
        "\(app(id))/appcast.xml"
    }

    /// 피드 토큰 목록·발급.
    public static func feedTokens(ofApp id: UUID) -> String {
        "\(app(id))/feed-tokens"
    }

    /// 옛 피드 주소에 토큰을 싣던 질의 항목의 이름.
    ///
    /// 폐기 예정이다. ``appcast(ofApp:token:)`` 을 쓴다.
    public static let feedTokenQueryItem = "token"

    /// 배포 토큰이 자기가 어느 앱의 것인지 확인하는 경로.
    ///
    /// CLI 는 앱 ID 를 모르고 토큰만 안다. 토큰이 스스로 밝히게 한다.
    public static let deployApp = "\(apiRoot)/deploy/app"

    public static func versions(ofApp id: UUID) -> String {
        "\(app(id))/versions"
    }

    public static func version(_ id: UUID) -> String {
        "\(apiRoot)/versions/\(id.uuidString)"
    }

    /// 업로드 완료 통지. 서명 잡 생성의 트리거.
    public static func completeUpload(versionID: UUID) -> String {
        "\(version(versionID))/complete"
    }

    public static func release(versionID: UUID) -> String {
        "\(version(versionID))/release"
    }

    /// 서명이 어디까지 왔는지 (ADR-0060).
    public static func signingStatus(versionID: UUID) -> String {
        "\(version(versionID))/signing"
    }

    /// 이 앱에 달린 별점과 피드백.
    public static func feedback(ofApp id: UUID) -> String {
        "\(apps)/\(id.uuidString)/feedback"
    }

    /// 이 앱에서 Sparkle 을 쓸 수 있는 상태인가 (ADR-0060).
    public static func sparkleFeedStatus(ofApp id: UUID) -> String {
        "\(app(id))/sparkle"
    }

    public static func download(versionID: UUID) -> String {
        "\(version(versionID))/download"
    }

    // MARK: - 서명 워커

    public static let workerRoot = "\(apiRoot)/worker"
    /// 워커가 long-poll 하는 경로. 워커 토큰으로 인증한다.
    public static let nextJob = "\(workerRoot)/jobs/next"

    public static func job(_ id: UUID) -> String {
        "\(workerRoot)/jobs/\(id.uuidString)"
    }

    public static let workerHeartbeat = "\(workerRoot)/heartbeat"
    /// 지금 배포 중인 워커 번들. 워커가 자기를 갈아끼울 때 본다 (ADR-0042).
    public static let workerRelease = "\(workerRoot)/release"

    // MARK: - 관리자

    public static let adminRoot = "\(apiRoot)/admin"
    public static let adminWorkers = "\(adminRoot)/workers"
    public static let adminUsers = "\(adminRoot)/users"
    public static let adminSettings = "\(adminRoot)/settings"

    /// 운영 파이프라인이 쓰는 경로. 운영 토큰으로 인증한다 (ADR-0043).
    public static let operatorRoot = "\(apiRoot)/ops"
    /// 워커 릴리스를 올리는 자리.
    public static let operatorWorkerReleases = "\(operatorRoot)/worker-releases"
    /// 스토어 앱에 지금 무엇이 올라가 있는지. CI 가 "이미 했나" 를 여기서 본다.
    public static let operatorStoreApp = "\(operatorRoot)/store-app"
    /// 운영 CI 가 스토어 앱의 베이스 번들을 올리는 자리 (ADR-0046).
    public static let operatorStoreAppBaseBundle = "\(operatorStoreApp)/base-bundle"
    /// 그 번들로 새 버전을 빌드시키는 자리.
    public static let operatorStoreAppBuild = "\(operatorStoreApp)/build"
}
