import AlleyShared
import Crypto
import Foundation
import Vapor

/// App Store Connect API 접근.
///
/// 하는 일은 셋이다. 인증서가 언제 만료되는지 보고, 특수 capability 를 쓰는 앱의
/// App ID 를 등록하고, 필요하면 Developer ID 프로필을 받아온다 (ADR-0005).
///
/// **이 서버가 아는 것은 조회와 등록까지다.** 서명은 워커가 자기 키체인의 인증서로
/// 한다(ADR-0002). 여기서 받아오는 인증서 정보는 "언제 만료되는가"를 사람에게 알리는
/// 용도이고, 개인키는 이 서버에 오지 않는다.
public struct AppStoreConnectClient: Sendable {
    /// Apple 이 허용하는 토큰 수명의 상한은 20분이다. 여유를 두고 짧게 잡는다.
    static let tokenLifetime: TimeInterval = 10 * 60
    static let baseURL = "https://api.appstoreconnect.apple.com/v1"

    public enum ClientError: Error, CustomStringConvertible {
        case notConfigured
        case invalidPrivateKey(String)
        case unauthorized
        case api(status: Int, detail: String)
        case transport(String)
        case malformedResponse

        public var description: String {
            switch self {
            case .notConfigured:
                return """
                    App Store Connect 연동이 설정되지 않았습니다. \
                    ASC_ISSUER_ID, ASC_KEY_ID, ASC_PRIVATE_KEY 를 채우세요.
                    """
            case .invalidPrivateKey(let detail):
                return "ASC_PRIVATE_KEY 를 읽지 못했습니다: \(detail)"
            case .unauthorized:
                return "App Store Connect 가 키를 거부했습니다. 발급자 ID 와 키 ID 를 확인하세요."
            case .api(let status, let detail):
                return "App Store Connect 가 \(status) 를 돌려줬습니다: \(detail)"
            case .transport(let detail):
                return "App Store Connect 에 연결하지 못했습니다: \(detail)"
            case .malformedResponse:
                return "App Store Connect 응답을 해석하지 못했습니다."
            }
        }
    }

    private let config: AppConfig.AppStoreConnectConfig
    private let client: any Client

    public init(config: AppConfig.AppStoreConnectConfig, client: any Client) {
        self.config = config
        self.client = client
    }

    // MARK: - 인증서

    /// 이 팀의 인증서 목록.
    ///
    /// Developer ID 만 걸러내지 않고 전부 가져온다. 만료가 임박한 것이 무엇이든
    /// 관리자가 알아야 하고, 종류별로 걸러내는 것은 화면이 할 일이다.
    public func certificates() async throws -> [ASCCertificate] {
        let response: ASCResponse<ASCCertificateAttributes> = try await get(
            "/certificates",
            query: ["limit": "200"]
        )
        return response.data.map { item in
            ASCCertificate(
                id: item.id,
                name: item.attributes.name ?? item.attributes.displayName ?? "(이름 없음)",
                type: item.attributes.certificateType ?? "알 수 없음",
                serialNumber: item.attributes.serialNumber,
                expiresAt: item.attributes.expirationDate
            )
        }
    }

    // MARK: - App ID

    /// 포털에 등록된 App ID 목록.
    public func bundleIDs() async throws -> [ASCBundleID] {
        let response: ASCResponse<ASCBundleIDAttributes> = try await get(
            "/bundleIds",
            query: ["limit": "200", "filter[platform]": "MAC_OS"]
        )
        return response.data.compactMap { item in
            guard let identifier = item.attributes.identifier else { return nil }
            return ASCBundleID(
                id: item.id,
                identifier: identifier,
                name: item.attributes.name ?? identifier,
                platform: item.attributes.platform ?? "MAC_OS"
            )
        }
    }

    /// App ID 를 등록한다.
    ///
    /// 와일드카드(`com.example.*`)와 explicit 둘 다 이 경로로 만든다. Apple 쪽은
    /// 식별자에 `*` 가 들어 있는지로 구분한다 (ADR-0005).
    public func registerBundleID(identifier: String, name: String) async throws -> ASCBundleID {
        let body = ASCCreateRequest(
            data: .init(
                type: "bundleIds",
                attributes: [
                    "identifier": identifier,
                    "name": name,
                    "platform": "MAC_OS",
                ]
            )
        )
        let response: ASCSingleResponse<ASCBundleIDAttributes> = try await post("/bundleIds", body: body)
        return ASCBundleID(
            id: response.data.id,
            identifier: response.data.attributes.identifier ?? identifier,
            name: response.data.attributes.name ?? name,
            platform: response.data.attributes.platform ?? "MAC_OS"
        )
    }

    // MARK: - 인증 토큰

    /// App Store Connect 가 요구하는 ES256 JWT.
    ///
    /// 키가 P-256 이라 서명이 ES256 이고, 헤더에 키 ID 가 들어가야 Apple 이 어떤 키로
    /// 검증할지 안다. 수명은 짧게 두고 요청마다 새로 만든다. 캐시해서 아끼는 것보다
    /// 만료된 토큰으로 실패하는 쪽이 훨씬 성가시다.
    func makeToken(now: Date = Date()) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: config.privateKeyPEM)
        } catch {
            throw ClientError.invalidPrivateKey(
                "PEM 형식인지 확인하세요. -----BEGIN PRIVATE KEY----- 로 시작해야 합니다."
            )
        }

        let header = ASCTokenHeader(kid: config.keyID)
        let payload = ASCTokenPayload(
            iss: config.issuerID,
            iat: Int(now.timeIntervalSince1970),
            exp: Int(now.addingTimeInterval(Self.tokenLifetime).timeIntervalSince1970)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let signingInput = [
            Self.base64URL(try encoder.encode(header)),
            Self.base64URL(try encoder.encode(payload)),
        ].joined(separator: ".")

        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    /// JWT 가 쓰는 base64. 패딩을 떼고 URL 안전 문자로 바꾼다.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 요청

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents(string: Self.baseURL + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw ClientError.malformedResponse }

        return try await perform(
            method: .GET,
            url: url,
            encodeBody: { _ in }
        )
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        guard let url = URL(string: Self.baseURL + path) else {
            throw ClientError.malformedResponse
        }
        return try await perform(
            method: .POST,
            url: url,
            encodeBody: { request in
                request.headers.contentType = .json
                try request.content.encode(body, as: .json)
            }
        )
    }

    private func perform<T: Decodable>(
        method: HTTPMethod,
        url: URL,
        encodeBody: (inout ClientRequest) throws -> Void
    ) async throws -> T {
        let token = try makeToken()

        let response: ClientResponse
        do {
            response = try await client.send(
                method,
                headers: ["Authorization": "Bearer \(token)"],
                to: URI(string: url.absoluteString),
                beforeSend: encodeBody
            )
        } catch {
            throw ClientError.transport(String(describing: error))
        }

        guard response.status != .unauthorized else { throw ClientError.unauthorized }
        guard response.status.code < 300 else {
            throw ClientError.api(
                status: Int(response.status.code),
                detail: Self.errorDetail(from: response) ?? "이유 없음"
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try response.content.decode(T.self, using: decoder)
        } catch {
            throw ClientError.malformedResponse
        }
    }

    /// Apple 이 주는 오류 본문에서 사람이 읽을 부분만 꺼낸다.
    static func errorDetail(from response: ClientResponse) -> String? {
        struct Payload: Decodable {
            struct Item: Decodable {
                var title: String?
                var detail: String?
            }
            var errors: [Item]?
        }
        guard let payload = try? response.content.decode(Payload.self),
              let errors = payload.errors, !errors.isEmpty
        else {
            return nil
        }
        return errors
            .map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ": ") }
            .joined(separator: " / ")
    }
}

// MARK: - 토큰 페이로드

struct ASCTokenHeader: Encodable {
    var alg = "ES256"
    var kid: String
    var typ = "JWT"
}

struct ASCTokenPayload: Encodable {
    var iss: String
    var iat: Int
    var exp: Int
    /// Apple 이 요구하는 고정값.
    var aud = "appstoreconnect-v1"
}

// MARK: - 응답 형태

/// App Store Connect 는 JSON:API 형식을 쓴다. 우리가 쓰는 부분만 옮긴다.
struct ASCResponse<Attributes: Decodable>: Decodable {
    struct Item: Decodable {
        var id: String
        var attributes: Attributes
    }
    var data: [Item]
}

struct ASCSingleResponse<Attributes: Decodable>: Decodable {
    struct Item: Decodable {
        var id: String
        var attributes: Attributes
    }
    var data: Item
}

struct ASCCreateRequest<Attributes: Encodable>: Encodable {
    struct Payload: Encodable {
        var type: String
        var attributes: Attributes
    }
    var data: Payload
}

struct ASCCertificateAttributes: Decodable {
    var name: String?
    var displayName: String?
    var certificateType: String?
    var serialNumber: String?
    var expirationDate: Date?
}

struct ASCBundleIDAttributes: Decodable {
    var identifier: String?
    var name: String?
    var platform: String?
}
