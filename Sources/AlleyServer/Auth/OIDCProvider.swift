import Foundation
import JWTKit
import Vapor

/// 표준 OIDC 공급자와의 왕복 (ADR-0047).
///
/// 예전에는 Google 의 엔드포인트가 상수로 박혀 있었다. 그래서 Google Workspace 를
/// 쓰지 않는 조직은 이 제품을 쓸 수 없었다. **사내 배포 도구가 특정 회사의 계정
/// 체계를 요구하는 것은 그 자체로 진입 장벽이다.**
///
/// 이제 `issuer` 하나만 받고 나머지는 공급자가 스스로 알려준다. Google 도 같은
/// 길로 지나간다. `issuer` 를 주지 않으면 Google 이 기본값이라 이미 돌고 있는
/// 스토어는 설정을 바꾸지 않아도 된다.
///
/// | 공급자 | `OIDC_ISSUER` |
/// | --- | --- |
/// | Google Workspace | `https://accounts.google.com` (기본값) |
/// | Microsoft Entra ID | `https://login.microsoftonline.com/<tenant>/v2.0` |
/// | Okta | `https://<org>.okta.com` |
/// | Keycloak | `https://<host>/realms/<realm>` |
///
/// 이 서버가 confidential client 다. 클라이언트 시크릿은 서버에만 있고 스토어 앱이나
/// 브라우저로 나가지 않는다.
public struct OIDCProvider: Sendable {
    /// 요청하는 스코프. 전부 표준이고 비민감이라 공급자 심사가 필요 없다.
    public static let scopes = ["openid", "email", "profile"]

    let config: AppConfig.OAuthConfig
    let metadata: OIDCMetadata

    public init(config: AppConfig.OAuthConfig, metadata: OIDCMetadata) {
        self.config = config
        self.metadata = metadata
    }

    /// 사용자를 보낼 로그인 주소.
    /// - Parameter forcesReauthentication: 공급자에게 인증을 다시 시킬지. 방금
    ///   로그아웃한 사람이 다시 들어올 때 참이다 (`reauthenticationCookieName`).
    public func authorizationURL(state: String, forcesReauthentication: Bool = false) -> String {
        var components = URLComponents(string: metadata.authorizationEndpoint)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        // 어느 계정으로 들어갈지 고르게 한다. 여러 계정을 쓰는 사람이 많고, 이것이
        // 없으면 브라우저가 기억하는 계정으로 조용히 들어간다. 강제력은 없어서
        // 실제 판단은 돌아온 ID 토큰을 보고 서버가 한다.
        //
        // **`select_account` 는 공급자마다 다르게 다뤄진다.** Google 은 계정 고르는
        // 화면을 띄우지만 Keycloak 은 그런 화면이 없어 무시한다. 그래서 방금 로그아웃한
        // 사람에게는 `login` 을 함께 보낸다. 그쪽은 "세션이 있어도 다시 인증시켜라" 라서
        // 어느 공급자에서나 같은 뜻으로 통한다.
        items.append(
            .init(name: "prompt", value: forcesReauthentication ? "login select_account" : "select_account")
        )

        // 기존 질의 항목을 지우지 않는다. Keycloak 처럼 endpoint 에 이미 질의가
        // 붙어 있는 공급자가 있다.
        components.queryItems = (components.queryItems ?? []) + items
        return components.url!.absoluteString
    }

    /// 공급자 세션까지 끝내고 돌아올 주소. 공급자가 그 자리를 내주지 않으면 nil.
    ///
    /// **`id_token_hint` 를 싣지 않는다.** 세션 토큰은 우리가 서명한 것이고 공급자의
    /// ID 토큰은 로그인 때 쓰고 버린다(ADR-0008). 규격은 힌트가 없으면 공급자가 사람에게
    /// 확인을 받아도 된다고 하는데, 그 화면이 뜨는 편이 조용히 남의 세션을 끊는 것보다
    /// 낫다.
    ///
    /// 돌아올 주소는 공급자에 등록돼 있어야 한다. Keycloak 은 클라이언트의
    /// `post.logout.redirect.uris`, Entra 와 Okta 는 각자의 로그아웃 URI 목록이다.
    public func endSessionURL(postLogoutRedirectURI: String) -> String? {
        guard let endpoint = metadata.endSessionEndpoint,
              var components = URLComponents(string: endpoint)
        else {
            return nil
        }
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "client_id", value: config.clientID),
            .init(name: "post_logout_redirect_uri", value: postLogoutRedirectURI),
        ]
        return components.url?.absoluteString
    }

    /// 인가 코드를 토큰으로 교환한다. 서버에서 공급자로 직접 나간다.
    public func exchange(code: String, client: any Client) async throws -> TokenResponse {
        let response = try await client.post(URI(string: metadata.tokenEndpoint)) { request in
            try request.content.encode(
                TokenRequest(
                    code: code,
                    clientID: config.clientID,
                    clientSecret: config.clientSecret,
                    redirectURI: config.redirectURI
                ),
                as: .urlEncodedForm
            )
        }

        guard response.status == .ok else {
            // 공급자가 돌려준 오류 본문에는 시크릿이 들어 있지 않지만, 그대로
            // 사용자에게 노출하지는 않는다.
            let body = response.body.map { String(buffer: $0) } ?? ""
            throw OIDCError.tokenExchangeFailed(status: response.status, body: body)
        }
        return try response.content.decode(TokenResponse.self)
    }

    struct TokenRequest: Content {
        var code: String
        var clientID: String
        var clientSecret: String
        var redirectURI: String
        var grantType = "authorization_code"

        enum CodingKeys: String, CodingKey {
            case code
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case redirectURI = "redirect_uri"
            case grantType = "grant_type"
        }
    }

    public struct TokenResponse: Content, Sendable {
        /// 사용자 신원이 담긴 JWT. 우리가 실제로 쓰는 것은 이것뿐이다.
        public var idToken: String
        public var accessToken: String?
        public var expiresIn: Int?
        public var tokenType: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }
}

// MARK: - 공급자가 알려주는 것

/// `{issuer}/.well-known/openid-configuration` 이 내려주는 값 중 우리가 쓰는 것.
///
/// 엔드포인트를 설정으로 받지 않는 이유는 **네 개를 손으로 적게 하면 하나가 틀리기
/// 때문**이다. 공급자가 자기 주소를 가장 잘 알고, 바뀌면 이 문서가 먼저 바뀐다.
public struct OIDCMetadata: Codable, Sendable, Equatable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var jwksURI: String
    /// 공급자 세션을 끝내는 자리. 규격에서 선택이라 없는 공급자가 있다.
    ///
    /// **Google 은 이것을 내주지 않는다.** 그쪽에서는 우리 쿠키만 지우고 다음 로그인에
    /// 재인증을 요구하는 것으로 끝낸다 (`reauthenticationCookieName`).
    public var endSessionEndpoint: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case endSessionEndpoint = "end_session_endpoint"
    }

    public init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        jwksURI: String,
        endSessionEndpoint: String? = nil
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.jwksURI = jwksURI
        self.endSessionEndpoint = endSessionEndpoint
    }

    /// discovery 문서가 있는 자리.
    ///
    /// 규격이 "issuer 뒤에 이 경로를 붙인다" 로 정해두었다. issuer 끝의 슬래시는
    /// 사람마다 적는 방식이 다르므로 여기서 다듬는다.
    public static func discoveryURL(issuer: String) -> String {
        let trimmed = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        return "\(trimmed)/.well-known/openid-configuration"
    }

    /// 돌려받은 문서가 정말 이 공급자의 것인지 본다.
    ///
    /// **`issuer` 가 우리가 물어본 곳과 같아야 한다.** 다르면 그 문서는 다른 곳을
    /// 가리키고 있고, 그대로 쓰면 우리가 모르는 서버로 사용자를 보내게 된다.
    /// 규격도 이 검사를 요구한다.
    func validated(against requested: String) throws -> OIDCMetadata {
        let expected = requested.hasSuffix("/") ? String(requested.dropLast()) : requested
        let actual = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer

        // 여러 조직을 한 주소로 받는 엔드포인트는 issuer 를 자리표시자로 내려준다.
        // Microsoft 의 `common` 이 `.../{tenantid}/v2.0` 을 주는 것이 그렇다.
        //
        // **그런 주소를 쓰면 안 된다.** 이 스토어는 한 조직의 것이고, 그 주소로 열면
        // 그 공급자에 계정이 있는 사람은 누구나 로그인을 시도할 수 있게 된다.
        // 이메일 도메인 검사가 뒤에 있긴 하지만, 문을 먼저 좁히는 편이 낫다.
        if actual.contains("{") {
            throw OIDCError.templatedIssuer(requested: expected, template: actual)
        }
        guard expected == actual else {
            throw OIDCError.issuerMismatch(expected: expected, actual: actual)
        }
        guard Self.isSafe(authorizationEndpoint),
              Self.isSafe(tokenEndpoint),
              Self.isSafe(jwksURI)
        else {
            throw OIDCError.insecureEndpoint
        }
        return self
    }
}

extension OIDCMetadata {
    /// 이 주소로 토큰과 공개키를 주고받아도 되는가.
    ///
    /// https 면 된다. 예외는 loopback 인데, 거기로 가는 트래픽은 이 기계를 벗어나지
    /// 않기 때문이다. 브라우저도 `http://localhost` 를 보안 컨텍스트로 친다.
    ///
    /// **이 예외가 없으면 로컬에 공급자를 띄워 시험할 수 없다.** 그러면 이 경로를
    /// 확인할 길이 진짜 조직 계정뿐이고, 그건 기여자에게 요구할 수 없는 것이다.
    /// `PUBLIC_BASE_URL` 도 같은 이유로 같은 예외를 갖고 있다(ADR-0027).
    static func isSafe(_ endpoint: String) -> Bool {
        if endpoint.hasPrefix("https://") { return true }
        guard let host = URLComponents(string: endpoint)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

// MARK: - ID 토큰

/// 공급자가 서명해 보내는 신원.
///
/// `hd` 는 Google 고유다. 다른 공급자에는 없고, 그때는 이메일 도메인만 본다
/// (`EmailDomainPolicy`).
public struct OIDCIdentityToken: JWTPayload, Sendable {
    public var issuer: IssuerClaim
    public var subject: SubjectClaim
    public var audience: AudienceClaim
    public var expiration: ExpirationClaim
    public var email: String?
    public var emailVerified: Bool?
    public var name: String?
    public var picture: String?
    /// Google Workspace 의 조직 도메인. 다른 공급자에는 없다.
    public var hostedDomain: String?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case audience = "aud"
        case expiration = "exp"
        case email
        case emailVerified = "email_verified"
        case name
        case picture
        case hostedDomain = "hd"
    }

    /// 서명이 맞는 것만으로는 부족하다. **누가 누구에게 발급한 토큰인지**를 본다.
    ///
    /// `aud` 를 확인하지 않으면 같은 공급자의 다른 앱에 발급된 토큰으로 우리 서버에
    /// 들어올 수 있다. `iss` 를 확인하지 않으면 우리가 신뢰하기로 한 곳이 아닌
    /// 데서 온 토큰을 받는다. 둘 다 규격이 요구하는 검사다.
    public func verify(using algorithm: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }

    /// 서명 검증이 끝난 토큰에 대고 나머지를 확인한다.
    func check(issuer expectedIssuer: String, audience clientID: String) throws {
        let expected = expectedIssuer.hasSuffix("/") ? String(expectedIssuer.dropLast()) : expectedIssuer
        let actual = issuer.value.hasSuffix("/") ? String(issuer.value.dropLast()) : issuer.value
        guard expected == actual else {
            throw OIDCError.issuerMismatch(expected: expected, actual: actual)
        }
        do {
            try audience.verifyIntendedAudience(includes: clientID)
        } catch {
            throw OIDCError.audienceMismatch
        }
    }

    /// `email_verified` 를 문자열로 보내는 공급자가 있다. 규격은 불리언이지만
    /// `"true"` 로 오는 구현이 실제로 있어서 둘 다 받는다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.issuer = try container.decode(IssuerClaim.self, forKey: .issuer)
        self.subject = try container.decode(SubjectClaim.self, forKey: .subject)
        self.audience = try container.decode(AudienceClaim.self, forKey: .audience)
        self.expiration = try container.decode(ExpirationClaim.self, forKey: .expiration)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.picture = try container.decodeIfPresent(String.self, forKey: .picture)
        self.hostedDomain = try container.decodeIfPresent(String.self, forKey: .hostedDomain)

        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .emailVerified) {
            self.emailVerified = flag
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .emailVerified) {
            self.emailVerified = text.lowercased() == "true"
        } else {
            self.emailVerified = nil
        }
    }
}

// MARK: - 오류

public enum OIDCError: Error, CustomStringConvertible {
    case tokenExchangeFailed(status: HTTPStatus, body: String)
    case discoveryFailed(issuer: String, status: HTTPStatus)
    case issuerMismatch(expected: String, actual: String)
    case templatedIssuer(requested: String, template: String)
    case insecureEndpoint
    case audienceMismatch
    case missingEmail

    public var description: String {
        switch self {
        case .tokenExchangeFailed(let status, let body):
            return "토큰 교환에 실패했습니다 (\(status.code)): \(body)"
        case .discoveryFailed(let issuer, let status):
            return """
                로그인 공급자 설정을 읽지 못했습니다 (\(status.code)). \
                OIDC_ISSUER 가 맞는지 확인하세요: \(OIDCMetadata.discoveryURL(issuer: issuer))
                """
        case .issuerMismatch(let expected, let actual):
            return "로그인 공급자가 다릅니다. 기대: \(expected), 받음: \(actual)"
        case .templatedIssuer(let requested, let template):
            return """
                여러 조직이 함께 쓰는 주소입니다(\(requested)). 이 스토어는 한 조직의                 것이라 조직 하나를 가리키는 주소가 필요합니다. 공급자가 알려준 형태는                 \(template) 이니, 가운데를 조직의 테넌트 ID 로 바꿔 OIDC_ISSUER 에                 넣으세요.
                """
        case .insecureEndpoint:
            return """
                로그인 공급자가 https 가 아닌 주소를 알려줬습니다. \
                평문으로는 토큰이 오가는 것을 누구든 볼 수 있습니다. \
                (로컬에서 시험할 때 쓰는 localhost 만 예외입니다.)
                """
        case .audienceMismatch:
            return "이 스토어에 발급된 토큰이 아닙니다."
        case .missingEmail:
            return """
                로그인 공급자가 이메일을 주지 않았습니다. \
                클라이언트에 email 스코프가 허용돼 있는지 확인하세요.
                """
        }
    }
}
