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
    /// Slack 봇 토큰. 사람에게 DM 을 보내는 데 쓴다.
    ///
    /// **웹훅으로는 DM 을 못 보낸다.** Incoming Webhook 은 만들 때 정한 채널 하나에만
    /// 쓴다. 서명 실패는 그 버전을 올린 사람이 고치는 일이라 그 사람에게 닿아야 하고,
    /// 그러려면 봇 토큰과 이메일로 사용자를 찾는 권한(`users:read.email`)이 필요하다.
    ///
    /// 없으면 사람에게 보내는 알림만 조용히 건너뛴다. 앱 채널로 가는 알림은 그대로다.
    public var slackBotToken: String?
    /// 사용자와 워커가 접근하는 서버의 공개 주소. 콜백 URL 구성에 쓴다.
    public var publicBaseURL: String
    /// 업로드 통지 없이 버려진 `draft` 버전을 지우기까지 기다리는 시간(초).
    ///
    /// **presigned 업로드 URL 의 수명보다 반드시 길어야 한다.** 그보다 짧으면 아직
    /// 올리고 있는 파일의 자리를 지우게 된다 (`DraftSweep`).
    public var draftRetention: TimeInterval

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

        /// 기동하면서 마이그레이션을 적용할지. **기본값은 꺼짐** (ADR-0028).
        ///
        /// 권장 경로는 `alley-server migrate` 를 사람이 돌리는 것이다. 이 값은
        /// 일회성 명령을 돌릴 수단이 없는 플랫폼을 위한 문이다. 켜면 롤아웃마다
        /// 마이그레이션이 돌고, 실패하면 서버가 뜨지 않는다.
        public var migrateOnBoot: Bool
    }

    public struct StorageConfig: Sendable {
        /// **서버가** 스토리지에 붙는 주소. 컨테이너 네트워크 안에서만 풀리는 이름이어도 된다.
        ///
        /// MinIO 같은 셀프호스팅 스토리지도 그대로 쓴다.
        public var endpoint: String?

        /// **클라이언트에게 내주는** 주소. presigned URL 이 이 주소 위에 만들어진다.
        ///
        /// 안 주면 `endpoint` 를 그대로 쓴다. 서버와 브라우저가 같은 주소로 스토리지에
        /// 닿는 환경(로컬 개발)에서는 나눌 이유가 없다. 나뉘는 곳은 서버가
        /// `http://minio:9000` 으로 붙고 브라우저는 그 이름을 풀 수 없는 배포 환경이다.
        public var publicEndpoint: String?

        public var region: String
        public var bucket: String

        /// 버킷 안에서 이 서버가 쓰는 자리. 앞뒤 슬래시 없이 정규화된 값이다. 없으면 빈 문자열.
        ///
        /// 버킷 하나를 여러 프로젝트가 나눠 쓰고 각자 프리픽스 하나만 소유하는 배포
        /// 환경에서 필요하다. 버킷 루트에 쓰면 권한에서 막힌다.
        public var keyPrefix: String

        /// 액세스 키. 둘 다 없으면 SDK 기본 자격증명 체인을 쓴다 (ADR-0024).
        public var accessKeyID: String?
        public var secretAccessKey: String?

        /// MinIO 등 가상 호스트 방식을 못 쓰는 스토리지를 위한 옵션.
        public var usePathStyle: Bool
        /// 발급하는 presigned URL의 유효 시간(초).
        ///
        /// **임시 자격증명으로 서명하면 이 값이 상한일 뿐이다.** 실제 수명은 서명에 쓴
        /// 세션 토큰이 살아 있는 동안까지다 (ADR-0024).
        public var presignedURLTTL: Int

        /// presigned URL 을 서명할 기준 주소.
        ///
        /// 서명은 **호스트를 포함해서** 계산된다. 한 호스트로 서명하고 다른 호스트로
        /// 내주면 스토리지가 403 으로 거절한다. 그래서 공개 주소가 있으면 그쪽으로 서명한다.
        public var presignEndpoint: String? {
            publicEndpoint.flatMap { $0.isEmpty ? nil : $0 }
                ?? endpoint.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public struct OAuthConfig: Sendable {
        /// OIDC 공급자의 issuer. 엔드포인트는 여기서 discovery 로 알아낸다 (ADR-0047).
        ///
        /// 기본값이 Google 인 것은 그 전에 이 제품이 Google 만 쓸 수 있었기 때문이다.
        /// 이미 돌고 있는 스토어가 설정을 바꾸지 않아도 그대로 돌아간다.
        public var issuer: String
        public var clientID: String
        public var clientSecret: String
        /// 공급자에 등록한 리다이렉트 URI.
        public var redirectURI: String
        /// 로그아웃할 때 공급자 세션까지 끊을지.
        ///
        /// **기본은 끄기다.** 켜면 같은 IdP 를 쓰는 다른 사내 도구에서도 로그아웃된다.
        /// 스토어 하나에서 나가려고 누른 버튼치고는 멀리 간다.
        ///
        /// 공용 맥을 여럿이 쓰는 곳에서는 켜는 편이 맞다. 끈 상태에서는 우리 쿠키만
        /// 지우고, 다음 로그인에 재인증을 요구하는 것으로 끝낸다
        /// (`reauthenticationCookieName`).
        ///
        /// 켜려면 공급자에 로그아웃 후 돌아올 주소를 등록해야 한다. Keycloak 은
        /// 클라이언트의 `post.logout.redirect.uris` 다.
        public var endsProviderSessionOnLogout: Bool

        public init(
            issuer: String = OAuthConfig.googleIssuer,
            clientID: String,
            clientSecret: String,
            redirectURI: String,
            endsProviderSessionOnLogout: Bool = false
        ) {
            self.issuer = issuer
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
            self.endsProviderSessionOnLogout = endsProviderSessionOnLogout
        }

        public static let googleIssuer = "https://accounts.google.com"

        /// Google 을 쓰고 있는가. 화면 문구와 설정 안내에만 쓴다.
        public var isGoogle: Bool { issuer == Self.googleIssuer }
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
        /// 값 하나씩은 멀쩡한데 조합이 성립하지 않는 경우.
        case incomplete(reason: String)

        public var description: String {
            switch self {
            case .missing(let key):
                return "필수 환경변수 \(key) 가 설정되지 않았습니다."
            case .invalid(let key, let reason):
                return "환경변수 \(key) 값이 올바르지 않습니다: \(reason)"
            case .incomplete(let reason):
                return "환경변수 설정이 반쪽입니다: \(reason)"
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

        /// 새 이름을 먼저 보고 없으면 옛 이름을 본다. 둘 다 없으면 **새 이름으로**
        /// 실패한다. 없는 값을 찾아 넣을 사람에게 알려줄 이름은 새것이다.
        func requiredEither(_ key: String, _ legacyKey: String) throws -> String {
            guard let value = optional(key) ?? optional(legacyKey) else {
                throw LoadError.missing(key: key)
            }
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

        /// 오브젝트 키 프리픽스를 정규화한다.
        ///
        /// `foo`, `foo/`, `/foo/` 를 모두 같은 값으로 본다. 셋 다 사람이 같은 뜻으로
        /// 적는 값인데 그대로 이어붙이면 `//` 가 생기거나 루트를 가리키게 된다.
        /// S3 는 `//` 를 빈 이름의 디렉터리로 받아들여서, 틀린 채로 조용히 동작한다.
        func keyPrefix(_ key: String) -> String {
            guard let raw = optional(key) else { return "" }
            return raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        /// 액세스 키는 둘 다 주거나 둘 다 안 주거나다.
        ///
        /// 하나만 준 것은 설정 실수다. 그대로 뜨면 기본 자격증명 체인으로 조용히
        /// 넘어가서, 방금 넣은 키가 왜 안 먹는지 아무도 모르게 된다.
        func accessKeyPair() throws -> (String?, String?) {
            let id = optional("S3_ACCESS_KEY_ID")
            let secret = optional("S3_SECRET_ACCESS_KEY")
            switch (id, secret) {
            case (nil, .some), (.some, nil):
                throw LoadError.incomplete(
                    reason: "S3_ACCESS_KEY_ID 와 S3_SECRET_ACCESS_KEY 는 둘 다 주거나 둘 다 비워야 합니다. "
                        + "둘 다 비우면 SDK 기본 자격증명 체인(환경변수, 인스턴스에 붙은 역할 등)을 씁니다."
                )
            default:
                return (id, secret)
            }
        }

        /// 공개 주소가 http 면 로컬에서만 받아준다.
        ///
        /// 이 값의 스킴 하나가 세션 쿠키의 `Secure` 를 정한다(`AuthController`).
        /// 배포 환경에 http 주소를 넣으면 `Secure` 없는 쿠키가 나가고, 그러면 세션
        /// 토큰이 평문으로 오갈 수 있는 상태가 **아무 경고 없이** 만들어진다.
        /// 증상도 없다. 로그인은 잘 되고, 잘못됐다는 것을 아무도 모른다.
        ///
        /// 로컬 개발은 http 로 계속 돌아야 하므로 loopback 만 예외로 둔다.
        func validatedPublicBaseURL() throws -> String {
            let raw = try required("PUBLIC_BASE_URL")
            guard let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host, !host.isEmpty
            else {
                throw LoadError.invalid(
                    key: "PUBLIC_BASE_URL",
                    reason: "scheme 과 host 를 갖춘 절대 주소여야 합니다. 예: https://store.example.com"
                )
            }
            guard ["http", "https"].contains(scheme) else {
                throw LoadError.invalid(
                    key: "PUBLIC_BASE_URL",
                    reason: "http 또는 https 여야 합니다. 지금 값의 scheme 은 '\(scheme)' 입니다."
                )
            }

            let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"]
            guard scheme == "https" || loopback.contains(host.lowercased()) else {
                throw LoadError.invalid(
                    key: "PUBLIC_BASE_URL",
                    reason: "https 로 적어야 합니다. 이 값의 scheme 이 세션 쿠키의 Secure 속성을 정하는데, "
                        + "http 로 두면 Secure 없는 쿠키가 나갑니다. "
                        + "TLS 를 앞단(인그레스·리버스 프록시)에서 끊고 있다면 밖에서 보이는 https 주소를 적으세요. "
                        + "TLS 가 아직 없다면 그것을 먼저 붙이세요. Google OAuth 도 loopback 이 아닌 http "
                        + "리다이렉트 주소를 거부합니다. 로컬 개발은 http://localhost:8080 처럼 적으면 됩니다."
                )
            }
            return raw
        }

        /// 세션 토큰을 서명하는 키가 충분히 긴지 본다.
        ///
        /// HMAC-SHA256 을 쓴다(`configureJWT`). RFC 2104 는 키를 해시 출력 길이 이상으로
        /// 두라고 한다. 그보다 짧으면 서명을 깨는 비용이 SHA-256 의 강도가 아니라
        /// **키를 맞히는 비용**으로 내려앉는다. `.env.example` 을 그대로 복사해 뜬 서버가
        /// 그 상태다.
        ///
        /// 그래서 32 바이트로 잡는다. 사람이 손으로 지은 문구는 이 길이를 잘 넘기지
        /// 못하고, 무작위로 만들면 넘기지 않기가 더 어렵다.
        func validatedJWTSecret() throws -> String {
            let secret = try required("JWT_SECRET")
            let minimumBytes = 32
            guard secret.utf8.count >= minimumBytes else {
                throw LoadError.invalid(
                    key: "JWT_SECRET",
                    reason: "\(minimumBytes) 바이트 이상이어야 합니다. 지금 \(secret.utf8.count) 바이트입니다. "
                        + "HMAC-SHA256 서명 키라 해시 출력(32 바이트)보다 짧으면 서명을 깨는 비용이 그만큼 "
                        + "내려갑니다. `openssl rand -base64 48` 로 만든 값을 넣으세요. "
                        + "바꾸면 이미 나간 세션이 모두 끊깁니다."
                )
            }
            return secret
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

        let (accessKeyID, secretAccessKey) = try accessKeyPair()

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
            database: DatabaseConfig(
                url: try required("DATABASE_URL"),
                migrateOnBoot: boolean("MIGRATE_ON_BOOT", default: false)
            ),
            storage: StorageConfig(
                endpoint: optional("S3_ENDPOINT"),
                publicEndpoint: optional("S3_PUBLIC_ENDPOINT"),
                region: optional("S3_REGION") ?? "us-east-1",
                bucket: try required("S3_BUCKET"),
                keyPrefix: keyPrefix("S3_KEY_PREFIX"),
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                usePathStyle: boolean("S3_USE_PATH_STYLE", default: true),
                presignedURLTTL: try integer("S3_PRESIGNED_URL_TTL", default: 3600)
            ),
            // 옛 이름 `GOOGLE_*` 도 그대로 받는다. 이미 돌고 있는 스토어의 설정을
            // 깨뜨리지 않는다 (ADR-0047).
            oauth: OAuthConfig(
                issuer: optional("OIDC_ISSUER") ?? OAuthConfig.googleIssuer,
                clientID: try requiredEither("OIDC_CLIENT_ID", "GOOGLE_CLIENT_ID"),
                clientSecret: try requiredEither("OIDC_CLIENT_SECRET", "GOOGLE_CLIENT_SECRET"),
                redirectURI: try required("OAUTH_REDIRECT_URI"),
                endsProviderSessionOnLogout: boolean(
                    "OIDC_LOGOUT_ENDS_PROVIDER_SESSION", default: false
                )
            ),
            security: SecurityConfig(
                jwtSecret: try validatedJWTSecret(),
                sessionTTL: try integer("SESSION_TTL", default: 60 * 60 * 24 * 7)
            ),
            appStoreConnect: appStoreConnectConfig(),
            slackBotToken: optional("SLACK_BOT_TOKEN"),
            publicBaseURL: try validatedPublicBaseURL(),
            // 기본 사흘. presigned 업로드 URL 의 기본 수명(1시간)의 일흔두 배라
            // 아직 올리는 중인 업로드를 지울 여지가 없고, 금요일 저녁에 버려진
            // 업로드가 월요일 아침까지는 남아 있다.
            draftRetention: TimeInterval(try integer("DRAFT_RETENTION_HOURS", default: 72) * 3600)
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
