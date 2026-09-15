import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 운영 CI 가 스토어 앱을 자동으로 내보내는 경로 (ADR-0046).
///
/// **이 경로가 없으면 자동 릴리스가 사라진다.** 관리 화면에서만 빌드할 수 있으면
/// 제품 릴리스마다 사람이 파일을 받아 올리고 버튼을 눌러야 한다. 여기서 확인하는
/// 것은 화면이 하는 일과 같은 일을 토큰으로도 할 수 있다는 것이다.
@Suite("운영 토큰으로 스토어 앱 내보내기")
struct OperatorStoreAppTests {
    private func issueToken(on app: Application) async throws -> String {
        let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)
        let value = OperatorToken.generateToken()
        let token = OperatorToken(
            name: "alley-ops",
            tokenHash: OperatorToken.hash(token: value),
            createdByID: try admin.requireID()
        )
        try await token.save(on: app.db)
        return value
    }

    /// CI 가 `curl -F version=… -F bundle=@…` 로 보내는 모양.
    private func multipart(version: String, zip: Data) -> (HTTPHeaders, ByteBuffer) {
        let boundary = "alleyops"
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(
            type: "multipart", subType: "form-data", parameters: ["boundary": boundary]
        )
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"version\"\r\n\r\n")
        body.writeString("\(version)\r\n")
        body.writeString("--\(boundary)\r\n")
        body.writeString(
            "Content-Disposition: form-data; name=\"bundle\";"
                + " filename=\"alley-store-app-unsigned.zip\"\r\n"
        )
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zip)
        body.writeString("\r\n--\(boundary)--\r\n")
        return (headers, body)
    }

    private func prepareSettings(on app: Application) async throws {
        let settings = try await StoreAppSettings.loadOrSeed(
            on: app.db, config: app.alleyConfig, logger: app.logger
        )
        settings.bundleID = "com.example.alley.store"
        settings.appName = "우리 스토어"
        try await settings.save(on: app.db)
    }

    // MARK: - 인증

    /// 이 경로들은 조직 구성원의 맥에 설치될 번들을 받는다. 토큰이 없는 요청이
    /// 하나라도 통과하면 누구나 스토어 앱을 갈아끼울 수 있다.
    @Test("토큰 없이는 아무것도 못 한다")
    func requiresToken() async throws {
        try await withMigratedApp { app in
            let paths: [(HTTPMethod, String)] = [
                (.GET, APIPath.operatorStoreApp),
                (.POST, APIPath.operatorStoreAppBaseBundle),
                (.POST, APIPath.operatorStoreAppBuild),
            ]
            for (method, path) in paths {
                try await app.testing().test(method, path) {
                    #expect($0.status == .unauthorized, "\(method) \(path)")
                }
            }
        }
    }

    // MARK: - 한 바퀴

    @Test("베이스 번들을 올리고 빌드시킨다")
    func uploadsAndBuilds() async throws {
        try await withMigratedApp { app in
            _ = app.useFakeStorage()
            try await prepareSettings(on: app)
            let value = try await issueToken(on: app)
            let (headers, body) = multipart(
                version: "0.4.0", zip: StoreAppBundleRewriterTests.baseZip()
            )
            var withAuth = headers
            withAuth.bearerAuthorization = .init(token: value)

            try await app.testing().test(
                .POST, APIPath.operatorStoreAppBaseBundle, headers: withAuth, body: body
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(StoreAppStatusDTO.self)
                #expect(dto.baseBundleVersion == "0.4.0")
                #expect(dto.builds.isEmpty)
            }

            try await app.testing().test(
                .POST, APIPath.operatorStoreAppBuild, headers: .bearer(value)
            ) { response in
                #expect(response.status == .created)
                let dto = try response.content.decode(StoreAppStatusDTO.self)
                #expect(dto.bundleID == "com.example.alley.store")
                #expect(dto.builds.first?.shortVersion == "0.4.0")
                #expect(dto.builds.first?.buildNumber == 1)
            }
        }
    }

    /// **CI 의 재실행 판정이 여기에 달려 있다.** `adopt.yml` 은 이 목록에 자기 버전이
    /// 있는지 보고 건너뛴다. 빌드 번호는 서버가 스스로 올리므로 서버가 막아주지
    /// 않는다. 목록이 비거나 버전 문자열이 달라지면 릴리스마다 빌드가 하나씩 쌓인다.
    @Test("상태 조회로 이미 빌드한 버전을 알아본다")
    func statusTellsWhatIsAlreadyBuilt() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            try await prepareSettings(on: app)
            let value = try await issueToken(on: app)

            try await app.testing().test(.GET, APIPath.operatorStoreApp, headers: .bearer(value)) {
                let dto = try $0.content.decode(StoreAppStatusDTO.self)
                #expect(dto.baseBundleVersion == nil)
                #expect(dto.builds.isEmpty)
            }

            let (admin, _) = try await app.makeUser(email: "her@example.com", role: .admin)
            let settings = try await StoreAppSettings.loadOrSeed(
                on: app.db, config: app.alleyConfig, logger: app.logger
            )
            try await StoreAppBuildService.acceptBaseBundle(
                version: "0.4.0",
                data: StoreAppBundleRewriterTests.baseZip(),
                settings: settings,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )
            _ = try await StoreAppBuildService.build(
                settings: settings,
                icon: nil,
                serverURL: "https://store.example.com",
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )

            try await app.testing().test(.GET, APIPath.operatorStoreApp, headers: .bearer(value)) {
                let dto = try $0.content.decode(StoreAppStatusDTO.self)
                #expect(dto.baseBundleVersion == "0.4.0")
                #expect(dto.builds.map(\.shortVersion) == ["0.4.0"])
            }
        }
    }

    /// 베이스 번들 없이 빌드를 시키면 무엇이 없는지 말해줘야 한다. CI 로그에 남는
    /// 것이 이것뿐이라 "실패했다" 만 남으면 아무도 원인을 모른다.
    @Test("베이스 번들이 없으면 이유를 말하고 거절한다")
    func refusesWithoutBaseBundle() async throws {
        try await withMigratedApp { app in
            _ = app.useFakeStorage()
            try await prepareSettings(on: app)
            let value = try await issueToken(on: app)

            try await app.testing().test(
                .POST, APIPath.operatorStoreAppBuild, headers: .bearer(value)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("스토어 앱 번들을 먼저 올려주세요"))
            }
        }
    }
}
