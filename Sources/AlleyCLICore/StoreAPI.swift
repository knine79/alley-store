import AlleyProcess
import AlleyShared
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// CLI 가 서버에 거는 요청.
///
/// 배포 토큰으로 인증한다. 토큰이 앱 하나에 묶여 있어서(ADR-0015) 앱 ID 를 따로
/// 넘기지 않고, 서버에 "너는 어느 앱이냐"를 물어보는 것으로 시작한다.
public struct StoreAPI: Sendable {
    public enum APIError: Error, CustomStringConvertible {
        case unreachable(String)
        case unauthorized(String)
        case server(status: Int, reason: String?)
        case malformedResponse
        case transfer(String)

        public var description: String {
            switch self {
            case .unreachable(let detail):
                return "서버에 연결하지 못했습니다: \(detail)"
            case .unauthorized(let reason):
                return "인증에 실패했습니다: \(reason)"
            case .server(let status, let reason):
                return reason ?? "서버가 \(status) 를 돌려줬습니다."
            case .malformedResponse:
                return "서버 응답을 해석하지 못했습니다. 서버와 CLI 의 버전이 다를 수 있습니다."
            case .transfer(let detail):
                return "파일을 올리지 못했습니다: \(detail)"
            }
        }
    }

    private let config: CLIConfig

    public init(config: CLIConfig) {
        self.config = config
    }

    /// 이 토큰이 어느 앱의 것인지.
    public func currentApp() async throws -> AppDTO {
        try await get(APIPath.deployApp, as: AppDTO.self)
    }

    public func versions(ofApp id: UUID) async throws -> [VersionDTO] {
        try await get(APIPath.versions(ofApp: id), as: [VersionDTO].self)
    }

    /// 이 사람이 손댈 수 있는 앱들.
    ///
    /// 배포 토큰은 앱 하나에 묶여 있어서 `currentApp()` 하나면 됐다. 사람 토큰은
    /// 여러 앱을 다루므로 목록이 필요하다 (ADR-0060).
    public func apps() async throws -> [AppDTO] {
        try await get(APIPath.apps, as: [AppDTO].self)
    }

    /// 서명이 어디까지 왔는지. 실패했으면 갈래와 할 일이 함께 온다.
    public func signingStatus(versionID: UUID) async throws -> SigningStatusDTO {
        try await get(APIPath.signingStatus(versionID: versionID), as: SigningStatusDTO.self)
    }

    /// 앱에 넣을 `SUPublicEDKey` 와 지금 쓸 수 있는 상태인지.
    public func sparkle(appID: UUID) async throws -> SparkleFeedDTO {
        try await get(APIPath.sparkleFeedStatus(ofApp: appID), as: SparkleFeedDTO.self)
    }

    public func feedback(appID: UUID) async throws -> [FeedbackDTO] {
        try await get(APIPath.feedback(ofApp: appID), as: [FeedbackDTO].self)
    }

    // MARK: - 앱 상세 (이슈 #70)

    /// 앱 하나. 목록과 달리 받아간 횟수와 별점이 채워져 온다.
    public func app(id: UUID) async throws -> AppDTO {
        try await get(APIPath.app(id), as: AppDTO.self)
    }

    /// 보낸 항목만 바꾼다. 소유자와 관리자만 할 수 있다.
    public func updateApp(id: UUID, _ payload: UpdateAppRequest) async throws -> AppDTO {
        try await send(APIPath.app(id), method: "PATCH", body: payload, as: AppDTO.self)
    }

    /// 스크린샷 한 장을 덧붙인다. 형식과 크기는 서버가 본다.
    public func addScreenshot(_ image: Data, toApp id: UUID) async throws -> AppDTO {
        var request = authorized(APIPath.appScreenshots(ofApp: id))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = image
        return try await perform(request, as: AppDTO.self)
    }

    public func removeScreenshot(_ screenshotID: UUID, ofApp id: UUID) async throws -> AppDTO {
        var request = authorized(APIPath.appScreenshot(id, id: screenshotID))
        request.httpMethod = "DELETE"
        return try await perform(request, as: AppDTO.self)
    }

    /// 동영상을 올린다. 있던 것은 갈아끼운다 (이슈 #73). 형식·크기·길이는 서버가 본다.
    public func setVideo(_ video: Data, ofApp id: UUID) async throws -> AppDTO {
        var request = authorized(APIPath.appVideo(ofApp: id))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = video
        return try await perform(request, as: AppDTO.self)
    }

    public func removeVideo(ofApp id: UUID) async throws -> AppDTO {
        var request = authorized(APIPath.appVideo(ofApp: id))
        request.httpMethod = "DELETE"
        return try await perform(request, as: AppDTO.self)
    }

    /// 스크린샷 원본. 로그인한 요청에만 내주므로 토큰을 붙여 받는다 (ADR-0071).
    public func screenshot(_ screenshotID: UUID, ofApp id: UUID) async throws -> Data {
        try await load(authorized(APIPath.appScreenshot(id, id: screenshotID))).data
    }

    public func createVersion(
        _ payload: CreateVersionRequest,
        ofApp id: UUID
    ) async throws -> UploadTicket {
        try await send(
            APIPath.versions(ofApp: id),
            method: "POST",
            body: payload,
            as: UploadTicket.self
        )
    }

    public func completeUpload(
        versionID: UUID,
        sha256: String?
    ) async throws -> VersionDTO {
        try await send(
            APIPath.completeUpload(versionID: versionID),
            method: "POST",
            body: CompleteUploadRequest(sha256: sha256),
            as: VersionDTO.self
        )
    }

    /// 출시. `announce` 가 true 이면 앱의 출시 소식 채널에도 알린다 (ADR-0075).
    public func release(versionID: UUID, announce: Bool = false) async throws -> VersionDTO {
        try await send(
            APIPath.release(versionID: versionID),
            method: "POST",
            body: ReleaseVersionRequest(announce: announce),
            as: VersionDTO.self
        )
    }

    /// presigned URL 로 파일을 올린다.
    ///
    /// `curl` 을 쓴다. 워커와 같은 이유다. 수백 MB 짜리 앱을 메모리에 통째로 올리지
    /// 않으려면 스트리밍이 필요한데, 플랫폼마다 갖춰진 정도가 다르다.
    public func upload(_ file: URL, to urlString: String) async throws {
        let result = await Shell.runDetached(
            "/usr/bin/curl",
            [
                "--fail", "--silent", "--show-error",
                "--request", "PUT",
                // 서명에 없는 헤더를 붙이면 스토리지가 불일치로 거절한다.
                "--header", "Content-Type:",
                "--upload-file", file.path,
                urlString,
            ],
            timeout: 3600
        )
        guard result.succeeded else {
            throw APIError.transfer(result.combinedOutput)
        }
    }

    // MARK: - 보조

    private struct EmptyBody: Encodable {}

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func authorized(_ path: String) -> URLRequest {
        var request = URLRequest(url: config.serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await perform(authorized(path), as: type)
    }

    private func send<Body: Encodable, T: Decodable>(
        _ path: String,
        method: String,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        var request = authorized(path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request, as: type)
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, _) = try await load(request)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.malformedResponse
        }
    }

    /// 보내고, 실패한 응답을 사람이 읽을 오류로 바꾼다. 본문은 해석하지 않는다.
    private func load(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        guard http.statusCode != 401 else {
            throw APIError.unauthorized(
                reason(from: data) ?? "ALLEY_TOKEN 이 올바른지 확인하세요."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, reason: reason(from: data))
        }
        return (data, http)
    }

    private func reason(from data: Data) -> String? {
        struct Payload: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.reason
    }
}
