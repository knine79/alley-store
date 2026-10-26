import AlleyShared
import Foundation

/// 서버에 묻는 것 전부.
///
/// 앱 바이너리에는 어떤 조직 고유값도 들어가지 않는다(ADR-0003). 서버 주소는 사람이
/// 넣고, 이름과 색과 허용 도메인은 `/meta` 로 받아온다. 그래서 이 타입은 주소 하나만
/// 들고 시작한다.
struct StoreClient: Sendable {
    let server: URL
    var token: String?

    enum ClientError: LocalizedError {
        /// 서버에 닿지 못했다. 원인이 `URLError` 면 그 코드를 함께 싣는다.
        /// 끊긴 것(배너)과 인증서 같은 고쳐야 할 것(얼럿)을 가르는 데 쓴다.
        case unreachable(String, code: URLError.Code? = nil)
        case unauthorized
        case server(status: Int, reason: String?)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail, _):
                return "서버에 연결하지 못했습니다. 주소를 확인하세요.\n\(detail)"
            case .unauthorized:
                return "로그인이 만료됐습니다. 다시 로그인하세요."
            case .server(let status, let reason):
                return reason ?? "서버가 \(status) 를 돌려줬습니다."
            case .malformedResponse:
                return "서버 응답을 해석하지 못했습니다. 서버와 앱의 버전이 다를 수 있습니다."
            }
        }
    }

    // MARK: - 부트스트랩

    /// 로그인 전에 받아오는 스토어 정보.
    ///
    /// 주소가 맞는지 확인하는 역할도 겸한다. 이게 오면 Alley 서버가 맞다.
    func meta() async throws -> StoreMeta {
        try await get(APIPath.meta, as: StoreMeta.self, authenticated: false)
    }

    func currentUser() async throws -> UserDTO {
        try await get(APIPath.currentUser, as: UserDTO.self)
    }

    func exchange(code: String, verifier: String) async throws -> TokenExchangeResponse {
        try await post(
            APIPath.tokenExchange,
            body: TokenExchangeRequest(code: code, codeVerifier: verifier),
            as: TokenExchangeResponse.self,
            authenticated: false
        )
    }

    /// 지금 토큰을 새 토큰으로 바꾼다 (ADR-0069).
    func renewSession() async throws -> TokenExchangeResponse {
        var request = URLRequest(url: server.appendingPathComponent(APIPath.tokenRenewal))
        request.httpMethod = "POST"
        authorize(&request)
        return try await send(request, as: TokenExchangeResponse.self)
    }

    // MARK: - 카탈로그

    func apps() async throws -> [AppDTO] {
        try await get(APIPath.apps, as: [AppDTO].self)
    }

    func versions(ofApp id: UUID) async throws -> [VersionDTO] {
        try await get(APIPath.versions(ofApp: id), as: [VersionDTO].self)
    }

    /// 다운로드 URL 을 받는다. 서버는 이 시점에 이력을 남긴다.
    func downloadTicket(versionID: UUID) async throws -> DownloadTicket {
        try await get(APIPath.download(versionID: versionID), as: DownloadTicket.self)
    }

    /// 로그인해야 받는 그림 (앱 스크린샷). `AsyncImage` 는 토큰을 붙이지 못해 직접 받는다.
    ///
    /// 서버가 준 주소만 받는다. 다른 호스트로 토큰을 보내지 않는다.
    func authenticatedImage(at url: URL) async throws -> Data {
        guard Self.sameOrigin(url, server) else {
            throw ClientError.malformedResponse
        }
        var request = URLRequest(url: url)
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard http.statusCode != 401 else { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(status: http.statusCode, reason: nil)
        }
        return data
    }

    /// 앱 동영상을 틀 주소 (이슈 #73).
    ///
    /// 서버는 로그인을 확인한 뒤 잠깐 쓰는 스토리지 주소로 넘긴다(302). **넘김을 따라가지
    /// 않고 그 주소만 받는다.** 따라가면 수십 MB 를 여기서 다 받게 된다. 받은 주소는
    /// 플레이어에 넘기고, 플레이어가 필요한 구간만 청한다. 토큰을 붙일 필요도 없다.
    func videoLocation(at url: URL) async throws -> URL {
        guard Self.sameOrigin(url, server) else {
            throw ClientError.malformedResponse
        }
        var request = URLRequest(url: url)
        authorize(&request)
        let (_, response) = try await URLSession.shared.data(for: request, delegate: RedirectStopper())
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard http.statusCode != 401 else { throw ClientError.unauthorized }
        guard (300..<400).contains(http.statusCode),
              let raw = http.value(forHTTPHeaderField: "Location"),
              let location = URL(string: raw, relativeTo: url)?.absoluteURL
        else {
            throw ClientError.server(status: http.statusCode, reason: nil)
        }
        return location
    }

    /// 같은 출처인지. 기본 포트는 적었든 안 적었든 같게 본다 (`https://a` 와 `https://a:443`).
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }

    // MARK: - 피드백

    func feedback(ofApp id: UUID) async throws -> [FeedbackDTO] {
        try await get("\(APIPath.apiRoot)/apps/\(id.uuidString)/feedback", as: [FeedbackDTO].self)
    }

    func submitFeedback(
        _ payload: SubmitFeedbackRequest,
        versionID: UUID
    ) async throws -> FeedbackDTO {
        try await post(
            "\(APIPath.apiRoot)/versions/\(versionID.uuidString)/feedback",
            body: payload,
            as: FeedbackDTO.self
        )
    }

    // MARK: - 보조

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func get<T: Decodable>(
        _ path: String,
        as type: T.Type,
        authenticated: Bool = true
    ) async throws -> T {
        var request = URLRequest(url: server.appendingPathComponent(path))
        if authenticated { authorize(&request) }
        return try await send(request, as: type)
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        body: Body,
        as type: T.Type,
        authenticated: Bool = true
    ) async throws -> T {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if authenticated { authorize(&request) }
        return try await send(request, as: type)
    }

    private func authorize(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // 화면이 사라져 요청을 거둔 것이다. 서버에 닿지 못한 것으로 보이면 연결 배너가 뜬다.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw ClientError.unreachable(error.localizedDescription, code: error.code)
        } catch {
            throw ClientError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedResponse
        }
        // 토큰이 만료됐다는 뜻이다. 화면은 이걸 보고 로그인으로 돌려보낸다.
        guard http.statusCode != 401 else { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(status: http.statusCode, reason: reason(from: data))
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ClientError.malformedResponse
        }
    }

    /// 서버가 준 사람이 읽는 실패 이유.
    private func reason(from data: Data) -> String? {
        struct Payload: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.reason
    }
}

extension StoreClient {
    /// 사람이 적은 주소를 쓸 수 있는 형태로 다듬는다.
    ///
    /// 대부분 `store.example.com` 처럼 스킴 없이 적는다. 그대로 URL 로 만들면 경로로
    /// 해석돼서 아무 데도 닿지 않는다.
    static func normalize(serverAddress raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            // 사내 서버라도 평문으로 시작하게 두지 않는다. http 가 필요하면 직접 적는다.
            text = "https://" + text
        }
        // 뒤에 붙은 슬래시는 경로를 조립할 때 이중 슬래시를 만든다.
        while text.hasSuffix("/") {
            text.removeLast()
        }

        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            return nil
        }
        return url
    }
}

/// 넘김(3xx)을 따라가지 않는다. 응답의 `Location` 만 필요할 때 쓴다.
private final class RedirectStopper: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
