import AlleyShared
import Crypto
import Foundation
import Testing
import Vapor

@testable import AlleyServer

/// 테스트용 P-256 키.
///
/// 실제 App Store Connect 키가 아니다. 우리가 만드는 JWT 의 모양이 Apple 이 요구하는
/// 것과 같은지만 확인한다. 서명이 맞는지는 우리가 만든 키로 검증한다.
private func makeTestKey() -> (pem: String, publicKey: P256.Signing.PublicKey) {
    let key = P256.Signing.PrivateKey()
    return (key.pemRepresentation, key.publicKey)
}

@Suite("App Store Connect 토큰")
struct ASCTokenTests {
    private func client(pem: String) -> AppStoreConnectClient {
        AppStoreConnectClient(
            config: .init(issuerID: "issuer-1", keyID: "KEY123", privateKeyPEM: pem),
            client: FakeVaporClient()
        )
    }

    /// JWT 조각을 다시 사람이 읽을 형태로.
    private func decode(_ segment: String) throws -> [String: Any] {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        let data = try #require(Data(base64Encoded: base64))
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("Apple 이 요구하는 헤더와 클레임을 담는다")
    func buildsExpectedClaims() throws {
        let key = makeTestKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try client(pem: key.pem).makeToken(now: now)

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try decode(parts[0])
        #expect(header["alg"] as? String == "ES256")
        // 키 ID 가 없으면 Apple 이 어떤 키로 검증할지 모른다.
        #expect(header["kid"] as? String == "KEY123")

        let payload = try decode(parts[1])
        #expect(payload["iss"] as? String == "issuer-1")
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
        #expect(payload["iat"] as? Int == 1_800_000_000)
        // 수명은 Apple 상한(20분)보다 짧아야 한다.
        let lifetime = try #require(payload["exp"] as? Int) - 1_800_000_000
        #expect(lifetime > 0 && lifetime <= 20 * 60)
    }

    @Test("서명이 그 키로 검증된다")
    func signatureVerifies() throws {
        let key = makeTestKey()
        let token = try client(pem: key.pem).makeToken()

        let parts = token.split(separator: ".").map(String.init)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)

        var base64 = parts[2]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        let raw = try #require(Data(base64Encoded: base64))

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test("키를 읽지 못하면 부를 때가 아니라 지금 알려준다")
    func rejectsBadKey() {
        // 시크릿을 잘못 붙여넣는 것은 흔한 일이다. 요청을 보내고 나서 401 을 받는 것보다
        // 여기서 무엇이 잘못됐는지 말하는 편이 낫다.
        #expect(throws: AppStoreConnectClient.ClientError.self) {
            try client(pem: "-----BEGIN PRIVATE KEY-----\n쓰레기\n-----END PRIVATE KEY-----")
                .makeToken()
        }
    }

    @Test("base64url 에는 패딩과 특수문자가 없다")
    func base64URLIsClean() {
        let encoded = AppStoreConnectClient.base64URL(Data([251, 255, 190, 0, 1, 2]))
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }
}

@Suite("인증서 만료 판단")
struct CertificateExpiryTests {
    private func certificate(type: String, expiresIn days: Int) -> ASCCertificate {
        ASCCertificate(
            id: "1",
            name: "Developer ID Application: Example Inc.",
            type: type,
            expiresAt: Calendar(identifier: .gregorian).date(
                byAdding: .day, value: days, to: Date()
            )
        )
    }

    @Test("서명용 인증서를 알아본다")
    func recognizesSigningCertificate() {
        #expect(certificate(type: "DEVELOPER_ID_APPLICATION", expiresIn: 100).isDeveloperID)
        #expect(!certificate(type: "DISTRIBUTION", expiresIn: 100).isDeveloperID)
    }

    @Test("남은 날짜를 센다")
    func countsDaysLeft() {
        let days = certificate(type: "DEVELOPER_ID_APPLICATION", expiresIn: 45).daysUntilExpiry()
        // 시각 차이로 하루가 왔다 갔다 할 수 있다.
        #expect((44...45).contains(try! #require(days)))
    }

    @Test("이미 만료된 것은 음수로 나온다")
    func expiredIsNegative() {
        let days = try! #require(
            certificate(type: "DEVELOPER_ID_APPLICATION", expiresIn: -3).daysUntilExpiry()
        )
        #expect(days < 0)
    }

    @Test("만료일을 모르면 세지 않는다")
    func handlesMissingExpiry() {
        let certificate = ASCCertificate(id: "1", name: "이름", type: "DEVELOPER_ID_APPLICATION")
        #expect(certificate.daysUntilExpiry() == nil)
    }

    @Test("30일 안쪽의 서명용 인증서만 눈에 띄게 한다")
    func flagsOnlyUrgentSigningCertificates() {
        // 인증서 갱신은 손이 여러 번 가는 일이라 미리 알아야 한다.
        #expect(CertificateRow(certificate: certificate(type: "DEVELOPER_ID_APPLICATION", expiresIn: 10)).needsAttention)
        #expect(!CertificateRow(certificate: certificate(type: "DEVELOPER_ID_APPLICATION", expiresIn: 90)).needsAttention)
        // 서명에 쓰지 않는 인증서는 만료돼도 배포가 멈추지 않는다.
        #expect(!CertificateRow(certificate: certificate(type: "DISTRIBUTION", expiresIn: 1)).needsAttention)
    }
}

@Suite("App ID 판단")
struct BundleIDCoverageTests {
    private func bundleID(_ identifier: String) -> ASCBundleID {
        ASCBundleID(id: "1", identifier: identifier, name: "이름", platform: "MAC_OS")
    }

    @Test("와일드카드를 알아본다")
    func recognizesWildcard() {
        #expect(bundleID("com.example.*").isWildcard)
        #expect(!bundleID("com.example.tool").isWildcard)
    }

    @Test("와일드카드가 덮는 범위를 안다")
    func knowsCoverage() {
        let wildcard = bundleID("com.example.*")
        #expect(wildcard.covers("com.example.tool"))
        #expect(wildcard.covers("com.example.team.tool"))
        // 프리픽스가 다르면 못 덮는다. 이걸 틀리면 없는 프로필을 있다고 보게 된다.
        #expect(!wildcard.covers("com.other.tool"))
    }

    @Test("개별 App ID 는 자기 자신만 덮는다")
    func explicitCoversItself() {
        let explicit = bundleID("com.example.tool")
        #expect(explicit.covers("com.example.tool"))
        #expect(!explicit.covers("com.example.tool.helper"))
    }
}

@Suite("포털 화면")
struct PortalPageTests {
    @Test("관리자가 아니면 볼 수 없다")
    func requiresAdmin() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .GET, "/admin/portal", headers: .sessionCookie(token)
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("연동이 없으면 무엇을 채워야 하는지 알려준다")
    func explainsMissingConfiguration() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 조용히 빈 목록을 주면 "인증서가 없다"와 "물어볼 수 없다"가 구분되지 않는다.
            try await app.testing().test(
                .GET, "/admin/portal", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("ASC_ISSUER_ID"))
            }
        }
    }

    @Test("API 도 연동이 없으면 그렇게 답한다")
    func apiReportsNotConfigured() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .GET, "\(APIPath.adminRoot)/portal/certificates", headers: .bearer(token)
            ) { #expect($0.status == .serviceUnavailable) }
        }
    }
}

/// 아무것도 하지 않는 Vapor 클라이언트.
///
/// 토큰을 만드는 부분만 확인하므로 실제로 보낼 곳이 없다.
private struct FakeVaporClient: Client {
    var eventLoop: any EventLoop {
        EmbeddedEventLoop()
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        self
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        eventLoop.makeSucceededFuture(ClientResponse(status: .ok))
    }
}
