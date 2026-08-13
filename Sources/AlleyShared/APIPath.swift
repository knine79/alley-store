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
    /// 스토어 앱이 일회용 코드를 세션 토큰으로 교환하는 경로.
    public static let tokenExchange = "\(apiRoot)/auth/token"
    public static let currentUser = "\(apiRoot)/me"

    // MARK: - 앱 / 버전

    public static let apps = "\(apiRoot)/apps"

    public static func app(_ id: UUID) -> String {
        "\(apps)/\(id.uuidString)"
    }

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

    // MARK: - 관리자

    public static let adminRoot = "\(apiRoot)/admin"
    public static let adminWorkers = "\(adminRoot)/workers"
    public static let adminUsers = "\(adminRoot)/users"
    public static let adminSettings = "\(adminRoot)/settings"
}
