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
    /// App Store Connect API 연동. 설정하지 않으면 그 기능만 꺼진다.
    public var appStoreConnect: AppStoreConnectConfig?
    /// 사용자와 워커가 접근하는 서버의 공개 주소. 콜백 URL 구성에 쓴다.
    public var publicBaseURL: String

    /// 환경변수에만 존재하는 스토어 설정.
    ///
    /// 나머지 스토어 설정은 데이터베이스(`StoreSettings`)에 있고 관리자가 화면에서
    /// 바꾼다. 여기 남은 둘은 화면에서 바꿀 수 없는 이유가 각각 있다 (ADR-0011).
    public struct StoreConfig: Sendable {
        /// 최초 기동 시 admin으로 승격할 이메일 목록.
        ///
        /// 관리자가 한 명도 없을 때 첫 관리자를 만드는 값이라 관리자 화면에 둘 수 없다.
        public var initialAdminEmails: [String]

        /// 스토어 앱이 인증 콜백을 받을 커스텀 URL 스킴.
        ///
        /// 스토어 앱의 `Info.plist`에 박히는 값이다. 서버에서 혼자 바꾸면 이미 깔린
        /// 앱의 로그인이 깨진다. 앱과 서버가 함께 바뀌어야 하는 값이라 설정 화면에 두지 않는다.
        public var callbackURLScheme: String

        /// 설정 행이 아직 없을 때 한 번만 쓰이는 초기값.
        public var seed: StoreSeed
    }

    /// 데이터베이스에 설정 행이 없을 때 심는 초기값.
    ///
    /// 행이 생긴 뒤로는 무시된다. 셀프호스팅에서 `.env`만 채우면 일단 뜨게 하려고 둔다.
    public struct StoreSeed: Sendable {
        public var name: String
        public var logoURL: String?
        public var accentColor: String?
        public var allowedEmailDomains: [String]
        public var bundleIDPrefix: String?
        public var enforceBundleIDPrefix: Bool
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

    /// App Store Connect API 키.
    ///
    /// 셋 다 있어야 켜진다. 하나라도 없으면 연동 자체를 끈다. 절반만 설정된 상태로
    /// 뜬 뒤 부를 때가 되어서야 실패하는 것보다, 처음부터 없다고 말하는 편이 낫다.
    ///
    /// 비밀값이라 환경변수에 남는다(ADR-0011). 개인키는 파일 경로가 아니라 내용을
    /// 그대로 받는다. 컨테이너로 배포하면 파일을 넣는 것보다 시크릿을 주입하는 편이 쉽다.
    public struct AppStoreConnectConfig: Sendable {
        public var issuerID: String
        public var keyID: String
        /// `.p8` 파일의 내용. PEM 헤더를 포함한 그대로.
        public var privateKeyPEM: String
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

        /// 셋이 다 있을 때만 켠다.
        func appStoreConnectConfig() -> AppStoreConnectConfig? {
            guard let issuer = optional("ASC_ISSUER_ID"),
                  let keyID = optional("ASC_KEY_ID"),
                  let key = optional("ASC_PRIVATE_KEY")
            else {
                return nil
            }
            // 시크릿 관리 도구가 줄바꿈을 \n 으로 바꿔 넣는 경우가 흔하다.
            // PEM 은 줄바꿈이 의미를 가지므로 되돌린다.
            return AppStoreConnectConfig(
                issuerID: issuer,
                keyID: keyID,
                privateKeyPEM: key.replacingOccurrences(of: "\\n", with: "\n")
            )
        }

        return AppConfig(
            store: StoreConfig(
                initialAdminEmails: list("INITIAL_ADMIN_EMAILS").map { $0.lowercased() },
                callbackURLScheme: optional("STORE_APP_URL_SCHEME") ?? "alley",
                seed: StoreSeed(
                    name: optional("STORE_NAME") ?? "App Store",
                    logoURL: optional("STORE_LOGO_URL"),
                    accentColor: optional("STORE_ACCENT_COLOR"),
                    allowedEmailDomains: list("ALLOWED_EMAIL_DOMAINS").map { $0.lowercased() },
                    bundleIDPrefix: optional("BUNDLE_ID_PREFIX"),
                    enforceBundleIDPrefix: boolean("ENFORCE_BUNDLE_ID_PREFIX", default: true)
                )
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
            appStoreConnect: appStoreConnectConfig(),
            publicBaseURL: try required("PUBLIC_BASE_URL")
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
