import Logging
import NIOCore
import NIOHTTP1
import SotoCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// 컨테이너에 주입된 자격증명 엔드포인트에서 임시 키를 받아온다 (ADR-0038).
///
/// EKS Pod Identity 와 ECS 의 새 방식이 쓰는 경로다. 파드에 액세스 키를 주지 않고,
/// 대신 로컬 주소 하나와 토큰 파일 하나를 준다. 그 주소에 토큰을 붙여 물어보면
/// 15분짜리 임시 키가 나온다.
///
/// **Soto 는 이 방식을 모른다.** `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`(옛 ECS)
/// 까지만 본다. 그래서 기본 체인이 아무것도 못 찾고, presigned URL 을 만들려는
/// 순간에 `noProvider` 로 죽는다. 다른 언어 SDK 는 다 지원해서 플랫폼 문서는
/// "기본 체인이 알아서 집어간다" 고 말하는데, 우리만 아니었다.
struct PodIdentityCredentialProvider: CredentialProvider {
    /// 자격증명 엔드포인트가 돌려주는 것.
    private struct Response: Decodable {
        let accessKeyID: String
        let secretAccessKey: String
        let token: String
        let expiration: Date

        enum CodingKeys: String, CodingKey {
            case accessKeyID = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case token = "Token"
            case expiration = "Expiration"
        }
    }

    enum ProviderError: Error, CustomStringConvertible {
        case tokenUnreadable(path: String)
        case refused(status: UInt)
        case malformed

        var description: String {
            switch self {
            case .tokenUnreadable(let path):
                return "컨테이너 자격증명 토큰 파일을 읽지 못했습니다: \(path)"
            case .refused(let status):
                return "컨테이너 자격증명 엔드포인트가 \(status) 로 거절했습니다."
            case .malformed:
                return "컨테이너 자격증명 응답을 해석하지 못했습니다."
            }
        }
    }

    static let uriVariable = "AWS_CONTAINER_CREDENTIALS_FULL_URI"
    static let tokenFileVariable = "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"
    static let tokenVariable = "AWS_CONTAINER_AUTHORIZATION_TOKEN"

    let url: URL
    let httpClient: any AWSHTTPClient
    /// 기동 시점의 환경변수. 값은 변하지 않지만 토큰 **파일**은 갱신된다.
    let environment: [String: String]

    var description: String { "PodIdentityCredentialProvider" }

    /// 환경변수가 갖춰졌고 주소를 믿을 수 있을 때만 만들어진다.
    init?(
        httpClient: any AWSHTTPClient,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let raw = environment[Self.uriVariable],
              let url = URL(string: raw),
              Self.isTrustworthy(url)
        else {
            return nil
        }
        self.url = url
        self.httpClient = httpClient
        self.environment = environment
    }

    /// 이 주소에 토큰을 보내도 되는가.
    ///
    /// **토큰을 아무 데나 보내면 안 된다.** 환경변수 하나만 바꾸면 그 토큰이 밖으로
    /// 나가고, 받은 쪽은 우리 역할로 S3 에 접근할 수 있다. AWS SDK 들이 쓰는 규칙을
    /// 그대로 따른다. 루프백이거나, 자격증명 전용 링크로컬 주소이거나, https 여야
    /// 한다. 그 밖에는 아예 안 만든다.
    static func isTrustworthy(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        guard url.scheme == "http", let host = url.host else { return false }
        if host == "localhost" { return true }
        // 링크로컬 자격증명 주소. 169.254.170.2 는 옛 ECS, .23 은 Pod Identity 다.
        if ["169.254.170.2", "169.254.170.23", "fd00:ec2::23"].contains(host) { return true }
        if host.hasPrefix("127.") { return true }
        return host == "::1" || host == "[::1]"
    }

    /// 매번 파일에서 다시 읽는다. 토큰은 짧게 살고 kubelet 이 갈아 끼운다.
    ///
    /// 한 번 읽어두고 재사용하면 갱신 시점에 조용히 401 이 난다. 그때는 이미 자격증명
    /// 만료가 겹쳐서 무엇이 원인인지 알기 어렵다.
    func authorization() throws -> String? {
        if let path = environment[Self.tokenFileVariable] {
            guard let token = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw ProviderError.tokenUnreadable(path: path)
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return environment[Self.tokenVariable]
    }

    func getCredential(logger: Logger) async throws -> Credential {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "application/json")
        if let token = try authorization() {
            headers.add(name: "Authorization", value: token)
        }

        let response = try await httpClient.execute(
            request: AWSHTTPRequest(url: url, method: .GET, headers: headers, body: .init()),
            // 링크로컬 주소다. 여기서 오래 기다릴 이유가 없고, 못 받으면 요청 하나가
            // 실패하는 편이 낫다.
            timeout: .seconds(5),
            logger: logger
        )
        guard response.status == .ok else {
            throw ProviderError.refused(status: response.status.code)
        }

        let body = try await response.body.collect(upTo: 64 * 1024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(Response.self, from: Data(buffer: body)) else {
            throw ProviderError.malformed
        }

        return RotatingCredential(
            accessKeyId: decoded.accessKeyID,
            secretAccessKey: decoded.secretAccessKey,
            sessionToken: decoded.token,
            expiration: decoded.expiration
        )
    }
}

extension CredentialProviderFactory {
    /// 컨테이너 자격증명 엔드포인트. 없으면 다음 공급자로 넘어간다.
    ///
    /// 나섰는지 아닌지를 기동 로그에 남긴다. 안 남기면 "자격증명을 못 찾았다" 를
    /// 만났을 때 이 경로를 아예 안 탄 것인지 타고도 실패한 것인지 알 수 없다.
    static var podIdentity: CredentialProviderFactory {
        .custom { context in
            guard let provider = PodIdentityCredentialProvider(httpClient: context.httpClient)
            else {
                context.logger.notice("컨테이너 자격증명 엔드포인트가 없습니다. 다음 공급자로 넘어갑니다.")
                return NullCredentialProvider()
            }
            context.logger.notice("컨테이너 자격증명 엔드포인트를 씁니다: \(provider.url.absoluteString)")
            return RotatingCredentialProvider(context: context, provider: provider)
        }
    }
}
