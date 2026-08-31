import AlleyProcess
import AlleyShared
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 서버와 주고받는 것 전부.
///
/// 워커는 서버를 부르기만 하고 받지 않는다(ADR-0002). 그래서 여기 있는 것은 전부
/// 나가는 요청이다. 잡을 기다리는 것조차 우리가 거는 long-poll 이다.
public struct WorkerClient: Sendable {
    /// 잡이 없을 때 서버가 204 를 줄 때까지 붙잡고 있는 시간보다 넉넉해야 한다.
    /// 짧으면 정상적인 대기를 타임아웃으로 착각하고 끊는다.
    private static let pollSlack: TimeInterval = 15

    /// 아티팩트 전송에 허용하는 시간. 사내망에서 수백 MB 를 옮기는 것을 감안한다.
    private static let transferTimeout: TimeInterval = 3600

    public enum ClientError: Error, CustomStringConvertible {
        case badResponse(status: Int, reason: String?)
        case transport(any Error)
        case transfer(action: String, detail: String)
        case malformedPayload

        public var description: String {
            switch self {
            case .badResponse(let status, let reason):
                return "서버가 \(status) 를 돌려줬습니다: \(reason ?? "이유 없음")"
            case .transport(let error):
                return "서버에 연결하지 못했습니다: \(error.localizedDescription)"
            case .transfer(let action, let detail):
                return "아티팩트 \(action)에 실패했습니다: \(detail)"
            case .malformedPayload:
                return "서버 응답을 해석하지 못했습니다."
            }
        }
    }

    private let config: WorkerConfig
    private let session: URLSession

    public init(config: WorkerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - 잡

    /// 잡 하나를 기다린다. 그 사이에 아무것도 없으면 nil.
    public func nextJob() async throws -> SigningJobDTO? {
        var components = URLComponents(
            url: config.serverURL.appendingPathComponent(APIPath.nextJob),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "timeout", value: String(config.pollTimeout))]
        guard let url = components?.url else { throw ClientError.malformedPayload }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.pollTimeout) + Self.pollSlack
        authorize(&request)

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            return try decoder.decode(SigningJobDTO.self, from: data)
        case 204:
            return nil
        default:
            throw ClientError.badResponse(status: response.statusCode, reason: reason(from: data))
        }
    }

    /// 진행 상황을 보고한다. 성공·실패도 이걸로 알린다.
    public func report(_ update: SigningJobUpdate, for jobID: UUID) async throws {
        var request = URLRequest(
            url: config.serverURL.appendingPathComponent("\(APIPath.workerRoot)/jobs/\(jobID.uuidString)")
        )
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(update)
        authorize(&request)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.badResponse(status: response.statusCode, reason: reason(from: data))
        }
    }

    public func sendHeartbeat(_ heartbeat: WorkerHeartbeat) async throws {
        var request = URLRequest(
            url: config.serverURL.appendingPathComponent(APIPath.workerHeartbeat)
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(heartbeat)
        authorize(&request)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.badResponse(status: response.statusCode, reason: reason(from: data))
        }
    }

    // MARK: - 아티팩트

    /// presigned URL 에서 파일을 받아 디스크에 쓴다.
    ///
    /// 서버를 거치지 않는다(ADR-0009). 이 URL 자체가 자격증명이라 인증 헤더를 붙이지
    /// 않는다. 오히려 붙이면 서명이 헤더까지 포함해 계산된 경우 불일치가 난다.
    ///
    /// **`curl` 로 옮긴다.** 수백 MB 짜리 앱을 다루는데 `URLSession` 의 데이터 API 는
    /// 파일을 통째로 메모리에 올린다. 스트리밍 API 도 있지만 플랫폼마다 갖춰진 정도가
    /// 달라서, 어차피 `codesign` 을 부르려고 프로세스를 띄우는 워커에서는 `curl` 이
    /// 더 단순하고 예측 가능하다.
    public func download(from urlString: String, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let result = await Shell.runDetached(
            "/usr/bin/curl",
            ["--fail", "--silent", "--show-error", "--location", "--output", destination.path, urlString],
            timeout: Self.transferTimeout
        )
        guard result.succeeded else {
            throw ClientError.transfer(action: "내려받기", detail: result.combinedOutput)
        }
    }

    /// 결과물을 presigned URL 로 올린다.
    public func upload(_ file: URL, to urlString: String) async throws {
        let result = await Shell.runDetached(
            "/usr/bin/curl",
            [
                "--fail", "--silent", "--show-error",
                "--request", "PUT",
                // 서명에 포함되지 않은 헤더를 덧붙이면 스토리지가 서명 불일치로 거절한다.
                // curl 이 기본으로 붙이는 Content-Type 도 비운다.
                "--header", "Content-Type:",
                "--upload-file", file.path,
                urlString,
            ],
            timeout: Self.transferTimeout
        )
        guard result.succeeded else {
            throw ClientError.transfer(action: "올리기", detail: result.combinedOutput)
        }
    }

    // MARK: - 보조

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    }

    /// 서버가 준 사람이 읽는 실패 이유.
    private func reason(from data: Data) -> String? {
        struct Payload: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.reason
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.malformedPayload }
            return (data, http)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transport(error)
        }
    }

}
