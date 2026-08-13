import AlleyShared
import Foundation
import Vapor

/// 서버가 돌아가는 데 필요한 모든 설정.
///
/// 조직 고유값(스토어 이름, 허용 도메인, 인프라 접속 정보)은 전부 환경변수로 들어온다.
/// 코드에는 어떤 조직의 이름도, 어떤 호스팅 환경의 흔적도 남기지 않는다.
/// 그래야 이 서버를 누구나 자기 조직에 그대로 띄울 수 있다.
public struct AppConfig: Sendable {
    public var store: StoreConfig
    public var database: DatabaseConfig
    public var storage: StorageConfig
    public var oauth: OAuthConfig
    public var security: SecurityConfig
    /// 사용자와 워커가 접근하는 서버의 공개 주소. 콜백 URL 구성에 쓴다.
    public var publicBaseURL: String

    public struct StoreConfig: Sendable {
        public var name: String
        public var logoURL: String?
        public var accentColor: String?
        /// 로그인을 허용할 이메일 도메인. 비어 있으면 도메인 제한을 걸지 않는다.
        public var allowedEmailDomains: [String]
        /// 최초 기동 시 admin으로 승격할 이메일 목록.
        public var initialAdminEmails: [String]
        /// 앱 번들 ID에 요구할 프리픽스. 비어 있으면 강제하지 않는다.
        public var bundleIDPrefix: String?
        /// 프리픽스를 어길 때 등록을 막을지, 경고만 할지.
        public var enforceBundleIDPrefix: Bool
        /// 스토어 앱이 인증 콜백을 받을 커스텀 URL 스킴.
        public var callbackURLScheme: String
    }

    public struct DatabaseConfig: Sendable {
        public var url: String
    }

    public struct StorageConfig: Sendable {
        /// S3 호환 엔드포인트. MinIO 같은 셀프호스팅 스토리지도 그대로 쓴다.
        public var endpoint: String?
        public var region: String
        public var bucket: String
        public var accessKeyID: String
        public var secretAccessKey: String
        /// MinIO 등 가상 호스트 방식을 못 쓰는 스토리지를 위한 옵션.
        public var usePathStyle: Bool
        /// 발급하는 presigned URL의 유효 시간(초).
        public var presignedURLTTL: Int
    }

    public struct OAuthConfig: Sendable {
        public var clientID: String
        public var clientSecret: String
        /// 공급자에 등록한 리다이렉트 URI.
        public var redirectURI: String
    }

    public struct SecurityConfig: Sendable {
        /// 세션 토큰 서명에 쓰는 비밀키.
        public var jwtSecret: String
        /// 발급하는 세션 토큰의 유효 시간(초).
        public var sessionTTL: Int
    }
}

// MARK: - 환경변수 로딩

extension AppConfig {
    /// 설정이 없거나 잘못됐을 때의 실패. 기동 시점에 명확히 알리려고 별도 타입으로 둔다.
    public enum LoadError: Error, CustomStringConvertible {
        case missing(key: String)
        case invalid(key: String, reason: String)

        public var description: String {
            switch self {
            case .missing(let key):
                return "필수 환경변수 \(key) 가 설정되지 않았습니다."
            case .invalid(let key, let reason):
                return "환경변수 \(key) 값이 올바르지 않습니다: \(reason)"
            }
        }
    }

    /// 프로세스 환경변수에서 설정을 읽는다.
    ///
    /// 기본값을 주는 항목은 로컬 개발과 셀프호스팅 편의를 위한 것이고,
    /// 비밀값과 조직 고유값에는 기본값을 두지 않아 설정 누락이 조용히 넘어가지 않게 한다.
    public static func load(from environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AppConfig {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty else {
                throw LoadError.missing(key: key)
            }
            return value
        }

        func optional(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }

        func list(_ key: String) -> [String] {
            guard let raw = optional(key) else { return [] }
            return raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        func boolean(_ key: String, default defaultValue: Bool) -> Bool {
            guard let raw = optional(key)?.lowercased() else { return defaultValue }
            return ["1", "true", "yes", "on"].contains(raw)
        }

        func integer(_ key: String, default defaultValue: Int) throws -> Int {
            guard let raw = optional(key) else { return defaultValue }
            guard let value = Int(raw), value > 0 else {
                throw LoadError.invalid(key: key, reason: "양의 정수여야 합니다.")
            }
            return value
        }

        return AppConfig(
            store: StoreConfig(
                name: optional("STORE_NAME") ?? "App Store",
                logoURL: optional("STORE_LOGO_URL"),
                accentColor: optional("STORE_ACCENT_COLOR"),
                allowedEmailDomains: list("ALLOWED_EMAIL_DOMAINS").map { $0.lowercased() },
                initialAdminEmails: list("INITIAL_ADMIN_EMAILS").map { $0.lowercased() },
                bundleIDPrefix: optional("BUNDLE_ID_PREFIX"),
                enforceBundleIDPrefix: boolean("ENFORCE_BUNDLE_ID_PREFIX", default: true),
                callbackURLScheme: optional("STORE_APP_URL_SCHEME") ?? "alley"
            ),
            database: DatabaseConfig(url: try required("DATABASE_URL")),
            storage: StorageConfig(
                endpoint: optional("S3_ENDPOINT"),
                region: optional("S3_REGION") ?? "us-east-1",
                bucket: try required("S3_BUCKET"),
                accessKeyID: try required("S3_ACCESS_KEY_ID"),
                secretAccessKey: try required("S3_SECRET_ACCESS_KEY"),
                usePathStyle: boolean("S3_USE_PATH_STYLE", default: true),
                presignedURLTTL: try integer("S3_PRESIGNED_URL_TTL", default: 3600)
            ),
            oauth: OAuthConfig(
                clientID: try required("GOOGLE_CLIENT_ID"),
                clientSecret: try required("GOOGLE_CLIENT_SECRET"),
                redirectURI: try required("OAUTH_REDIRECT_URI")
            ),
            security: SecurityConfig(
                jwtSecret: try required("JWT_SECRET"),
                sessionTTL: try integer("SESSION_TTL", default: 60 * 60 * 24 * 7)
            ),
            publicBaseURL: try required("PUBLIC_BASE_URL")
        )
    }
}

// MARK: - 클라이언트로 내보내는 형태

extension AppConfig {
    /// 클라이언트 부트스트랩용 메타 정보로 변환한다.
    ///
    /// 비밀값이 섞여 나가지 않도록 노출할 항목만 명시적으로 옮긴다.
    public var storeMeta: StoreMeta {
        StoreMeta(
            storeName: store.name,
            logoURL: store.logoURL,
            accentColor: store.accentColor,
            allowedEmailDomains: store.allowedEmailDomains,
            callbackURLScheme: store.callbackURLScheme
        )
    }
}

// MARK: - Vapor 연동

extension Application {
    private struct AppConfigKey: StorageKey {
        typealias Value = AppConfig
    }

    public var alleyConfig: AppConfig {
        get {
            guard let config = storage[AppConfigKey.self] else {
                fatalError("AppConfig 가 설정되기 전에 접근했습니다. configure(_:) 를 먼저 호출하세요.")
            }
            return config
        }
        set { storage[AppConfigKey.self] = newValue }
    }
}
