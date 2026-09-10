import Logging
import NIOCore
import NIOHTTP1
import SotoCore
import Testing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import AlleyServer

/// 컨테이너에 주입된 자격증명 엔드포인트에서 임시 키를 받아온다 (ADR-0038).
///
/// Soto 가 이 방식을 몰라서 직접 붙였다. 배포된 서버가 presigned URL 을 만들지
/// 못하고 "스토리지 자격증명을 찾지 못했습니다" 로 죽던 것이 이 때문이다.
@Suite("컨테이너 자격증명")
struct PodIdentityCredentialTests {
    /// 정해둔 응답을 돌려주는 HTTP 클라이언트. 요청도 받아 적는다.
    private final class StubHTTPClient: AWSHTTPClient, @unchecked Sendable {
        let status: HTTPResponseStatus
        let body: String
        private(set) var seen: AWSHTTPRequest?

        init(status: HTTPResponseStatus = .ok, body: String) {
            self.status = status
            self.body = body
        }

        func execute(
            request: AWSHTTPRequest,
            timeout: TimeAmount,
            logger: Logger
        ) async throws -> AWSHTTPResponse {
            seen = request
            return AWSHTTPResponse(
                status: status, headers: [:], body: .init(string: body)
            )
        }
    }

    private static let payload = """
        {
          "AccessKeyId": "ASIAEXAMPLE",
          "SecretAccessKey": "wJalrEXAMPLEKEY",
          "Token": "IQoJb3JpZ2luX2VjEXAMPLE",
          "Expiration": "2026-09-10T12:00:00Z"
        }
        """

    // MARK: - 언제 나서는가

    @Test("환경변수가 없으면 아예 만들어지지 않는다")
    func absentWithoutEnvironment() {
        let client = StubHTTPClient(body: Self.payload)
        #expect(PodIdentityCredentialProvider(httpClient: client, environment: [:]) == nil)
    }

    @Test("주소가 있으면 만들어진다")
    func presentWithURI() {
        let client = StubHTTPClient(body: Self.payload)
        let provider = PodIdentityCredentialProvider(
            httpClient: client,
            environment: [
                PodIdentityCredentialProvider.uriVariable:
                    "http://169.254.170.23/v1/credentials"
            ]
        )
        #expect(provider != nil)
    }

    // MARK: - 어디로 토큰을 보내도 되는가

    /// **환경변수 하나만 바꾸면 토큰이 밖으로 나간다.** 받은 쪽은 우리 역할로
    /// 스토리지에 접근할 수 있다. 그래서 주소를 가린다.
    @Test("믿을 수 있는 주소만 받는다", arguments: [
        ("http://169.254.170.23/v1/credentials", true),
        ("http://169.254.170.2/v2/credentials", true),
        ("http://127.0.0.1:8080/creds", true),
        ("http://localhost/creds", true),
        ("https://credentials.example.com/creds", true),
        ("http://credentials.example.com/creds", false),
        ("http://169.254.169.254/creds", false),
        ("http://10.0.0.1/creds", false),
        ("ftp://169.254.170.23/creds", false),
    ])
    func gatesTheHost(address: String, allowed: Bool) throws {
        let url = try #require(URL(string: address))
        #expect(PodIdentityCredentialProvider.isTrustworthy(url) == allowed)
    }

    @Test("믿을 수 없는 주소면 만들어지지 않는다")
    func refusesUntrustedURI() {
        let client = StubHTTPClient(body: Self.payload)
        let provider = PodIdentityCredentialProvider(
            httpClient: client,
            environment: [
                PodIdentityCredentialProvider.uriVariable: "http://evil.example.com/creds"
            ]
        )
        #expect(provider == nil)
    }

    // MARK: - 받아온 것을 어떻게 다루는가

    @Test("응답을 자격증명으로 옮긴다")
    func decodesCredential() async throws {
        let client = StubHTTPClient(body: Self.payload)
        let provider = try #require(
            PodIdentityCredentialProvider(
                httpClient: client,
                environment: [
                    PodIdentityCredentialProvider.uriVariable:
                        "http://169.254.170.23/v1/credentials"
                ]
            )
        )

        let credential = try await provider.getCredential(logger: Logger(label: "test"))
        #expect(credential.accessKeyId == "ASIAEXAMPLE")
        #expect(credential.secretAccessKey == "wJalrEXAMPLEKEY")
        #expect(credential.sessionToken == "IQoJb3JpZ2luX2VjEXAMPLE")

        // 만료를 못 읽으면 갱신 시점을 알 수 없고, 그러면 15분 뒤에 조용히 403 이 난다.
        let expiring = try #require(credential as? (any ExpiringCredential))
        #expect(expiring.expiration == Date(timeIntervalSince1970: 1_789_041_600))
    }

    // MARK: - 토큰

    /// 토큰은 짧게 살고 kubelet 이 파일을 갈아 끼운다. 한 번 읽어두고 재사용하면
    /// 갱신 시점에 조용히 401 이 나고, 그때는 자격증명 만료와 겹쳐 원인을 찾기 어렵다.
    @Test("토큰을 부를 때마다 파일에서 다시 읽는다")
    func rereadsTokenFile() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-token-\(UUID().uuidString)")
        try "first-token\n".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let client = StubHTTPClient(body: Self.payload)
        let provider = try #require(
            PodIdentityCredentialProvider(
                httpClient: client,
                environment: [
                    PodIdentityCredentialProvider.uriVariable:
                        "http://169.254.170.23/v1/credentials",
                    PodIdentityCredentialProvider.tokenFileVariable: path.path,
                ]
            )
        )

        _ = try await provider.getCredential(logger: Logger(label: "test"))
        // 줄바꿈이 딸려 가면 엔드포인트가 401 로 거절한다.
        #expect(client.seen?.headers.first(name: "Authorization") == "first-token")

        try "second-token".write(to: path, atomically: true, encoding: .utf8)
        _ = try await provider.getCredential(logger: Logger(label: "test"))
        #expect(client.seen?.headers.first(name: "Authorization") == "second-token")
    }

    @Test("파일이 없으면 무엇을 못 읽었는지 말한다")
    func reportsMissingTokenFile() throws {
        let client = StubHTTPClient(body: Self.payload)
        let provider = try #require(
            PodIdentityCredentialProvider(
                httpClient: client,
                environment: [
                    PodIdentityCredentialProvider.uriVariable:
                        "http://169.254.170.23/v1/credentials",
                    PodIdentityCredentialProvider.tokenFileVariable: "/no/such/token",
                ]
            )
        )
        #expect(throws: PodIdentityCredentialProvider.ProviderError.self) {
            _ = try provider.authorization()
        }
    }

    /// 파일 대신 값으로 주는 배포도 있다.
    @Test("파일이 없으면 환경변수의 토큰을 쓴다")
    func fallsBackToTokenVariable() async throws {
        let client = StubHTTPClient(body: Self.payload)
        let provider = try #require(
            PodIdentityCredentialProvider(
                httpClient: client,
                environment: [
                    PodIdentityCredentialProvider.uriVariable:
                        "http://169.254.170.23/v1/credentials",
                    PodIdentityCredentialProvider.tokenVariable: "inline-token",
                ]
            )
        )
        _ = try await provider.getCredential(logger: Logger(label: "test"))
        #expect(client.seen?.headers.first(name: "Authorization") == "inline-token")
    }

    @Test("거절당하면 상태 코드를 남긴다")
    func reportsRefusal() async throws {
        let client = StubHTTPClient(status: .forbidden, body: "nope")
        let provider = try #require(
            PodIdentityCredentialProvider(
                httpClient: client,
                environment: [
                    PodIdentityCredentialProvider.uriVariable:
                        "http://169.254.170.23/v1/credentials"
                ]
            )
        )

        await #expect(throws: PodIdentityCredentialProvider.ProviderError.self) {
            _ = try await provider.getCredential(logger: Logger(label: "test"))
        }
    }

    @Test("응답이 깨져 있으면 실패한다")
    func rejectsMalformedBody() async throws {
        let client = StubHTTPClient(body: "{\"AccessKeyId\": \"only-this\"}")
        let provider = try #require(
            PodIdentityCredentialProvider(
                httpClient: client,
                environment: [
                    PodIdentityCredentialProvider.uriVariable:
                        "http://169.254.170.23/v1/credentials"
                ]
            )
        )

        await #expect(throws: PodIdentityCredentialProvider.ProviderError.self) {
            _ = try await provider.getCredential(logger: Logger(label: "test"))
        }
    }
}
