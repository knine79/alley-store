import AlleyShared
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 스토어 앱 로그인에 PKCE 를 붙인다 (ADR-0068).
///
/// 앱은 로그인을 기본 브라우저에서 하고, 코드는 커스텀 스킴 URL 로 받는다. 그 URL 은
/// 같은 스킴을 등록한 다른 앱도 받을 수 있다. 여기서 보는 것은 **코드만 가진 쪽은
/// 아무것도 받지 못하는가** 다.
@Suite("스토어 앱 로그인 PKCE")
struct AppSignInPKCETests {
    /// RFC 7636 부록 B 의 예. 앱(CryptoKit)과 서버(swift-crypto)가 같은 값을 내는지
    /// 이 값 하나로 양쪽에서 확인한다.
    static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    static let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    @Test("S256 challenge 가 RFC 7636 의 예와 같다")
    func challengeMatchesTheRFC() {
        #expect(PKCE.challenge(for: Self.rfcVerifier) == Self.rfcChallenge)
        #expect(PKCE.isWellFormed(challenge: Self.rfcChallenge))
        #expect(PKCE.isWellFormed(verifier: Self.rfcVerifier))
    }

    @Test("모양이 틀린 challenge 와 verifier 는 받지 않는다")
    func malformedValuesAreRejected() {
        #expect(!PKCE.isWellFormed(challenge: ""))
        #expect(!PKCE.isWellFormed(challenge: String(Self.rfcChallenge.dropLast())))
        #expect(!PKCE.isWellFormed(challenge: Self.rfcChallenge.replacingOccurrences(of: "-", with: "+")))
        #expect(!PKCE.isWellFormed(verifier: "too-short"))
        #expect(!PKCE.isWellFormed(verifier: String(repeating: "a", count: 129)))
    }

    @Test("challenge 가 묶인 코드는 맞는 verifier 에만 열린다")
    func aBoundCodeOpensOnlyForItsVerifier() {
        let (_, bound) = AuthCode.issue(userID: UUID(), codeChallenge: Self.rfcChallenge)
        #expect(bound.admits(verifier: Self.rfcVerifier))
        #expect(!bound.admits(verifier: nil))
        #expect(!bound.admits(verifier: String(repeating: "a", count: 43)))

        // challenge 없이 로그인하던 예전 앱과 CLI 는 그대로 된다.
        let (_, unbound) = AuthCode.issue(userID: UUID())
        #expect(unbound.admits(verifier: nil))
    }

    @Test("로그인 시작에 넘긴 challenge 가 서명된 state 에 실린다")
    func authorizeCarriesTheChallenge() async throws {
        try await withConfiguredApp { app in
            let state = try await Self.state(
                from: try await app.testing().sendRequest(
                    .GET, Self.authorizePath(challenge: Self.rfcChallenge)
                ),
                on: app
            )
            #expect(state.target == .app)
            #expect(state.codeChallenge == Self.rfcChallenge)
        }
    }

    /// 앱은 지금 기다리는 로그인의 값과 맞지 않는 콜백을 버린다. 브라우저가 복원한
    /// 예전 로그인 탭의 콜백이 지금 로그인을 가로채지 않게 한다.
    @Test("앱이 보낸 로그인별 값을 state 에 싣고 콜백에 돌려준다")
    func theAppStateRoundTrips() async throws {
        let appState = "attempt-0123456789abcdef"
        try await withConfiguredApp { app in
            let state = try await Self.state(
                from: try await app.testing().sendRequest(
                    .GET, Self.authorizePath(challenge: Self.rfcChallenge, appState: appState)
                ),
                on: app
            )
            #expect(state.appState == appState)
        }

        let callback = try #require(URLComponents(string: AuthController.appCallbackURL(
            scheme: "alleystore", code: "abc", appState: appState
        )))
        #expect(callback.scheme == "alleystore")
        #expect(callback.host == "auth")
        #expect(callback.queryItems?.first { $0.name == "code" }?.value == "abc")
        #expect(callback.queryItems?.first { $0.name == APIPath.appCallbackStateQueryItem }?.value == appState)

        // 값을 보내지 않던 예전 앱에는 예전 모양 그대로 돌려준다.
        #expect(AuthController.appCallbackURL(scheme: "alleystore", code: "abc", appState: nil)
            == "alleystore://auth?code=abc")
    }

    /// 콜백 URL 에 그대로 실려 나가는 값이다.
    @Test("모양이 틀린 로그인별 값으로는 로그인을 시작하지 않는다")
    func aMalformedAppStateIsRefused() async throws {
        try await withConfiguredApp { app in
            for bad in ["short", "has space and more chars", "slash/0123456789abcdef", String(repeating: "a", count: 129)] {
                let response = try await app.testing().sendRequest(
                    .GET, Self.authorizePath(challenge: Self.rfcChallenge, appState: bad)
                )
                #expect(response.status == .badRequest, "\(bad)")
            }
        }
    }

    @Test("challenge 없이 시작해도 예전처럼 로그인을 보낸다")
    func authorizeWithoutAChallengeStillWorks() async throws {
        try await withConfiguredApp { app in
            let state = try await Self.state(
                from: try await app.testing().sendRequest(.GET, Self.authorizePath(challenge: nil)),
                on: app
            )
            #expect(state.target == .app)
            #expect(state.codeChallenge == nil)
        }
    }

    /// 그대로 묶으면 아무도 교환할 수 없는 코드가 된다. 로그인을 끝까지 한 사람이
    /// 마지막에 영문 모를 실패를 본다.
    @Test("모양이 틀린 challenge 로는 로그인을 시작하지 않는다")
    func aMalformedChallengeIsRefused() async throws {
        try await withConfiguredApp { app in
            let response = try await app.testing().sendRequest(
                .GET, Self.authorizePath(challenge: "not-a-challenge")
            )
            #expect(response.status == .badRequest)
        }
    }

    @Test("맞는 verifier 를 가져오면 세션 토큰을 준다")
    func theRightVerifierGetsASession() async throws {
        try await withMigratedApp { app in
            let code = try await Self.issueBoundCode(on: app)

            try await Self.exchange(code, verifier: Self.rfcVerifier, on: app) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(TokenExchangeResponse.self)
                #expect(body.user.email == "user@example.com")
            }
        }
    }

    @Test("코드만 가로챈 쪽은 세션 토큰을 받지 못한다")
    func aCodeAloneGetsNothing() async throws {
        try await withMigratedApp { app in
            let code = try await Self.issueBoundCode(on: app)

            try await Self.exchange(code, verifier: nil, on: app) { response in
                #expect(response.status == .unauthorized)
            }
            try await Self.exchange(code, verifier: String(repeating: "a", count: 43), on: app) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    /// 가로챈 쪽이 틀린 값으로 한 번 불러 코드를 태워버리면 진짜 앱이 로그인을 다시
    /// 해야 한다.
    @Test("틀린 verifier 로 부른 것은 코드를 태우지 않는다")
    func aWrongVerifierDoesNotSpendTheCode() async throws {
        try await withMigratedApp { app in
            let code = try await Self.issueBoundCode(on: app)

            try await Self.exchange(code, verifier: nil, on: app) { response in
                #expect(response.status == .unauthorized)
            }
            try await Self.exchange(code, verifier: Self.rfcVerifier, on: app) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// 두 교환이 같은 표를 쓴다. 막지 않으면 앱 콜백에서 가로챈 코드를 verifier 없이
    /// CLI 교환으로 가져가 90일짜리 사람 토큰으로 바꿀 수 있다.
    @Test("앱이 받은 코드는 CLI 교환에서 바꿔주지 않는다")
    func anAppCodeIsNotACLICode() async throws {
        try await withMigratedApp { app in
            let code = try await Self.issueBoundCode(on: app)

            try await app.testing().test(
                .POST, APIPath.cliTokenExchange,
                beforeRequest: { request in
                    try request.content.encode(["code": code, "device": "my-mac"])
                }
            ) { response in
                #expect(response.status == .unauthorized)
            }
            let tokens = try await UserToken.query(on: app.db).count()
            #expect(tokens == 0)
        }
    }

    // MARK: - 보조

    private static func authorizePath(challenge: String?, appState: String? = nil) -> String {
        var components = URLComponents()
        components.path = APIPath.googleAuthorize
        components.queryItems = [URLQueryItem(name: APIPath.clientQueryItem, value: APIPath.appClient)]
        if let challenge {
            components.queryItems?.append(
                URLQueryItem(name: APIPath.codeChallengeQueryItem, value: challenge)
            )
        }
        if let appState {
            components.queryItems?.append(URLQueryItem(name: APIPath.appStateQueryItem, value: appState))
        }
        return components.string!
    }

    private static func state(from response: TestingHTTPResponse, on app: Application) async throws -> OAuthStateToken {
        let location = try #require(response.headers.first(name: .location))
        let raw = try #require(
            URLComponents(string: location)?.queryItems?.first { $0.name == "state" }?.value
        )
        return try await app.jwt.keys.verify(raw, as: OAuthStateToken.self)
    }

    /// 콜백이 하는 일 가운데 코드 발급만 따로 한다. 공급자 왕복은 시험에서 재현할 수 없다.
    private static func issueBoundCode(on app: Application) async throws -> String {
        let (user, _) = try await app.makeUser(email: "user@example.com", role: .user)
        let (plaintext, model) = AuthCode.issue(
            userID: try user.requireID(),
            codeChallenge: rfcChallenge
        )
        try await model.save(on: app.db)
        return plaintext
    }

    private static func exchange(
        _ code: String,
        verifier: String?,
        on app: Application,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.testing().test(
            .POST, APIPath.tokenExchange,
            beforeRequest: { request in
                try request.content.encode(TokenExchangeRequest(code: code, codeVerifier: verifier))
            },
            afterResponse: check
        )
    }
}
