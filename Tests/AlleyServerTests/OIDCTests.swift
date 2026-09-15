import Foundation
import JWTKit
import Testing
import Vapor

@testable import AlleyServer

@Suite("OIDC 공급자 설정")
struct OIDCMetadataTests {
    @Test("discovery 주소는 issuer 뒤에 붙인다")
    func discoveryURL() {
        #expect(
            OIDCMetadata.discoveryURL(issuer: "https://accounts.google.com")
                == "https://accounts.google.com/.well-known/openid-configuration"
        )
    }

    /// issuer 끝의 슬래시는 사람마다 적는 방식이 다르다. 붙여 쓰면 경로에 `//` 가
    /// 생기고 공급자에 따라 404 가 난다.
    @Test("issuer 끝의 슬래시를 다듬는다")
    func trimsTrailingSlash() {
        #expect(
            OIDCMetadata.discoveryURL(issuer: "https://login.example.com/realms/alley/")
                == "https://login.example.com/realms/alley/.well-known/openid-configuration"
        )
    }

    /// **규격이 요구하는 검사다.** 문서의 issuer 가 우리가 물어본 곳과 다르면
    /// 그 문서는 다른 곳을 가리키고 있고, 그대로 쓰면 우리가 모르는 서버로
    /// 사용자를 보내게 된다.
    @Test("문서가 다른 issuer 를 가리키면 거절한다")
    func rejectsIssuerMismatch() {
        let document = OIDCMetadata(
            issuer: "https://evil.example.com",
            authorizationEndpoint: "https://evil.example.com/auth",
            tokenEndpoint: "https://evil.example.com/token",
            jwksURI: "https://evil.example.com/jwks"
        )
        #expect(throws: (any Error).self) {
            try document.validated(against: "https://login.example.com")
        }
    }

    @Test("끝 슬래시만 다른 issuer 는 같은 것으로 본다")
    func acceptsTrailingSlashDifference() throws {
        let document = OIDCMetadata(
            issuer: "https://login.example.com/",
            authorizationEndpoint: "https://login.example.com/auth",
            tokenEndpoint: "https://login.example.com/token",
            jwksURI: "https://login.example.com/jwks"
        )
        _ = try document.validated(against: "https://login.example.com")
    }

    /// **실제로 돌려보다 찾았다.** Microsoft 의 `common` 엔드포인트는 여러 조직을
    /// 한 주소로 받으므로 issuer 를 `.../{tenantid}/v2.0` 이라는 자리표시자로 준다.
    ///
    /// 그 주소를 쓰면 그 공급자에 계정이 있는 사람은 누구나 로그인을 시도할 수 있게
    /// 된다. 이 스토어는 한 조직의 것이라 거절하는 것이 맞고, 대신 무엇을 넣어야
    /// 하는지 말해줘야 한다. "공급자가 다릅니다" 만으로는 알 수 없다.
    @Test("여러 조직이 함께 쓰는 주소는 무엇을 넣어야 하는지 말해준다")
    func rejectsTemplatedIssuer() {
        let document = OIDCMetadata(
            issuer: "https://login.microsoftonline.com/{tenantid}/v2.0",
            authorizationEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            tokenEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            jwksURI: "https://login.microsoftonline.com/common/discovery/v2.0/keys"
        )
        do {
            _ = try document.validated(
                against: "https://login.microsoftonline.com/common/v2.0"
            )
            Issue.record("거절했어야 합니다.")
        } catch let error as OIDCError {
            #expect(error.description.contains("테넌트 ID"))
            #expect(error.description.contains("OIDC_ISSUER"))
        } catch {
            Issue.record("OIDCError 가 아닙니다: \(error)")
        }
    }

    @Test("https 가 아닌 엔드포인트를 거절한다")
    func rejectsInsecureEndpoint() {
        let document = OIDCMetadata(
            issuer: "https://login.example.com",
            authorizationEndpoint: "http://login.example.com/auth",
            tokenEndpoint: "https://login.example.com/token",
            jwksURI: "https://login.example.com/jwks"
        )
        #expect(throws: (any Error).self) {
            try document.validated(against: "https://login.example.com")
        }
    }
}

@Suite("OIDC 로그인 주소")
struct OIDCAuthorizationURLTests {
    static func provider(
        authorizationEndpoint: String = "https://login.example.com/auth"
    ) -> OIDCProvider {
        OIDCProvider(
            config: AppConfig.OAuthConfig(
                issuer: "https://login.example.com",
                clientID: "client-id",
                clientSecret: "client-secret",
                redirectURI: "https://store.example.com/auth/google/callback"
            ),
            metadata: OIDCMetadata(
                issuer: "https://login.example.com",
                authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: "https://login.example.com/token",
                jwksURI: "https://login.example.com/jwks"
            )
        )
    }

    @Test("필요한 항목이 다 들어간다")
    func buildsAuthorizationURL() throws {
        let url = Self.provider().authorizationURL(state: "state-value")
        let items = try #require(URLComponents(string: url)?.queryItems)
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        #expect(values["client_id"] == "client-id")
        #expect(values["response_type"] == "code")
        #expect(values["state"] == "state-value")
        #expect(values["scope"] == "openid email profile")
        #expect(values["redirect_uri"] == "https://store.example.com/auth/google/callback")
    }

    /// Keycloak 처럼 엔드포인트에 이미 질의가 붙어 오는 공급자가 있다. 덮어쓰면
    /// 그 값이 사라지고, 사라진 것을 알아채기 어렵다.
    @Test("엔드포인트에 이미 붙은 질의를 지우지 않는다")
    func keepsExistingQueryItems() throws {
        let url = Self.provider(
            authorizationEndpoint: "https://login.example.com/auth?tenant=alley"
        ).authorizationURL(state: "s")
        let items = try #require(URLComponents(string: url)?.queryItems)

        #expect(items.contains { $0.name == "tenant" && $0.value == "alley" })
        #expect(items.contains { $0.name == "client_id" })
    }
}

@Suite("OIDC ID 토큰")
struct OIDCIdentityTokenTests {
    /// 서명은 맞아도 **누가 누구에게 발급했는지**를 봐야 한다. `aud` 를 안 보면 같은
    /// 공급자의 다른 앱에 발급된 토큰으로 우리 서버에 들어올 수 있다.
    @Test("우리 클라이언트에 발급된 토큰이 아니면 거절한다")
    func rejectsWrongAudience() throws {
        let token = Self.token(issuer: "https://login.example.com", audience: "다른-앱")
        #expect(throws: (any Error).self) {
            try token.check(issuer: "https://login.example.com", audience: "client-id")
        }
    }

    @Test("우리가 신뢰하는 공급자가 아니면 거절한다")
    func rejectsWrongIssuer() throws {
        let token = Self.token(issuer: "https://evil.example.com", audience: "client-id")
        #expect(throws: (any Error).self) {
            try token.check(issuer: "https://login.example.com", audience: "client-id")
        }
    }

    @Test("맞으면 통과한다")
    func acceptsMatching() throws {
        let token = Self.token(issuer: "https://login.example.com", audience: "client-id")
        try token.check(issuer: "https://login.example.com", audience: "client-id")
    }

    /// 규격은 불리언이지만 `"true"` 로 보내는 구현이 실제로 있다. 문자열로 오면
    /// 디코딩이 통째로 실패해서 로그인 자체가 막힌다.
    @Test("email_verified 를 문자열로 보내도 읽는다")
    func readsStringEmailVerified() throws {
        let json = """
            {"iss":"https://login.example.com","sub":"abc","aud":"client-id",
             "exp":\(Int(Date().timeIntervalSince1970) + 600),
             "email":"someone@example.com","email_verified":"true"}
            """
        let token = try JSONDecoder().decode(OIDCIdentityToken.self, from: Data(json.utf8))
        #expect(token.emailVerified == true)
    }

    @Test("email_verified 가 불리언이어도 읽는다")
    func readsBoolEmailVerified() throws {
        let json = """
            {"iss":"https://login.example.com","sub":"abc","aud":"client-id",
             "exp":\(Int(Date().timeIntervalSince1970) + 600),
             "email":"someone@example.com","email_verified":true}
            """
        let token = try JSONDecoder().decode(OIDCIdentityToken.self, from: Data(json.utf8))
        #expect(token.emailVerified == true)
    }

    /// `hd` 는 Google 고유다. 다른 공급자에는 없고 그때는 이메일 도메인만 본다.
    @Test("hd 가 없는 공급자도 읽는다")
    func readsTokenWithoutHostedDomain() throws {
        let json = """
            {"iss":"https://login.microsoftonline.com/t/v2.0","sub":"abc","aud":"client-id",
             "exp":\(Int(Date().timeIntervalSince1970) + 600),
             "email":"someone@example.com","name":"누군가"}
            """
        let token = try JSONDecoder().decode(OIDCIdentityToken.self, from: Data(json.utf8))
        #expect(token.hostedDomain == nil)
        #expect(token.name == "누군가")
    }

    static func token(issuer: String, audience: String) -> OIDCIdentityToken {
        let json = """
            {"iss":"\(issuer)","sub":"abc","aud":"\(audience)",
             "exp":\(Int(Date().timeIntervalSince1970) + 600),
             "email":"someone@example.com","email_verified":true}
            """
        // 이 시험들은 디코딩이 되는 것을 전제로 한다. 실패하면 위 시험이 먼저 잡는다.
        return try! JSONDecoder().decode(OIDCIdentityToken.self, from: Data(json.utf8))
    }
}

@Suite("JWT 머리 읽기")
struct JWTHeaderPeekTests {
    /// 공급자가 키를 바꾼 직후를 알아보는 값이다. 못 읽으면 그 순간 로그인이 멈춘다.
    @Test("헤더에서 kid 를 꺼낸다")
    func readsKeyID() {
        let header = Data(#"{"alg":"RS256","kid":"key-2026-09"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(JWTHeaderPeek.keyID(of: "\(header).payload.signature") == "key-2026-09")
    }

    @Test("kid 가 없거나 형식이 아니면 nil")
    func returnsNilWhenAbsent() {
        #expect(JWTHeaderPeek.keyID(of: "not-a-jwt") == nil)
        let header = Data(#"{"alg":"RS256"}"#.utf8).base64EncodedString()
        #expect(JWTHeaderPeek.keyID(of: "\(header).x.y") == nil)
    }
}

@Suite("OIDC 설정")
struct OIDCConfigTests {
    /// 이미 돌고 있는 스토어가 설정을 바꾸지 않아도 그대로 돌아가야 한다.
    @Test("옛 GOOGLE_* 이름을 그대로 받는다")
    func acceptsLegacyNames() throws {
        let config = try TestSupport.config()
        #expect(config.oauth.clientID == "client-id")
        #expect(config.oauth.issuer == AppConfig.OAuthConfig.googleIssuer)
        #expect(config.oauth.isGoogle)
    }

    @Test("새 이름이 있으면 그쪽이 이긴다")
    func newNamesWin() throws {
        let config = try TestSupport.config(overrides: [
            "OIDC_ISSUER": "https://login.microsoftonline.com/tenant/v2.0",
            "OIDC_CLIENT_ID": "entra-client",
            "OIDC_CLIENT_SECRET": "entra-secret",
        ])
        #expect(config.oauth.issuer == "https://login.microsoftonline.com/tenant/v2.0")
        #expect(config.oauth.clientID == "entra-client")
        #expect(!config.oauth.isGoogle)
    }

    /// 없는 값을 찾아 넣을 사람에게 알려줄 이름은 새것이어야 한다.
    @Test("둘 다 없으면 새 이름으로 실패한다")
    func failsWithNewName() {
        var environment = TestSupport.minimalEnvironment
        environment["GOOGLE_CLIENT_ID"] = nil

        do {
            _ = try AppConfig.load(from: environment)
            Issue.record("실패했어야 합니다.")
        } catch {
            #expect(String(describing: error).contains("OIDC_CLIENT_ID"))
        }
    }
}
