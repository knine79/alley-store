import Foundation
import Vapor

/// Google 과의 OAuth 왕복을 담당한다.
///
/// 이 서버가 confidential client 다. 클라이언트 시크릿은 서버에만 있고
/// 스토어 앱이나 브라우저로 나가지 않는다.
public struct GoogleOAuth: Sendable {
    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// 필요한 최소한만 요청한다. 전부 비민감 스코프라 Google 검증 절차가 필요 없다.
    public static let scopes = ["openid", "email", "profile"]

    let config: AppConfig.OAuthConfig

    public init(config: AppConfig.OAuthConfig) {
        self.config = config
    }

    /// 사용자를 보낼 Google 로그인 주소를 만든다.
    public func authorizationURL(state: String) -> String {
        var components = URLComponents(string: Self.authorizationEndpoint)!
        components.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            // 조직 계정으로 로그인할 것을 힌트로 준다. 강제력은 없으므로
            // 실제 판단은 돌아온 ID 토큰을 보고 서버가 한다.
            .init(name: "prompt", value: "select_account"),
        ]
        return components.url!.absoluteString
    }

    /// 인가 코드를 토큰으로 교환한다.
    ///
    /// 이 요청은 서버에서 Google 로 직접 나가고 클라이언트 시크릿을 함께 보낸다.
    public func exchange(code: String, client: any Client) async throws -> TokenResponse {
        let response = try await client.post(URI(string: Self.tokenEndpoint)) { request in
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
            // Google 이 돌려준 오류 본문에는 시크릿이 들어 있지 않지만,
            // 그대로 사용자에게 노출하지는 않는다.
            let body = response.body.map { String(buffer: $0) } ?? ""
            throw GoogleOAuthError.tokenExchangeFailed(status: response.status, body: body)
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

public enum GoogleOAuthError: Error, CustomStringConvertible {
    case tokenExchangeFailed(status: HTTPStatus, body: String)
    case missingAuthorizationCode
    case invalidState

    public var description: String {
        switch self {
        case .tokenExchangeFailed(let status, let body):
            return "Google 토큰 교환에 실패했습니다 (\(status.code)): \(body)"
        case .missingAuthorizationCode:
            return "인가 코드가 없습니다."
        case .invalidState:
            return "state 값이 유효하지 않습니다."
        }
    }
}
