import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 운영 파이프라인이 스토어를 갱신하는 경로 (ADR-0043).
///
/// 관리자 API 는 세션 쿠키로만 인증한다. 파이프라인은 브라우저가 아니라 로그인할
/// 수 없어서 별도 경로가 필요하다.
@Suite("운영 토큰 경로")
struct OperatorAPITests {
    /// 발급한 토큰과 그 값, 그리고 발급한 관리자.
    ///
    /// 관리자를 함께 돌려주는 이유는 `token.createdBy` 가 여기서는 안 읽혀 있기
    /// 때문이다. 실제 요청 경로에서는 인증 미들웨어가 함께 읽어온다.
    private func issueToken(
        on app: Application
    ) async throws -> (token: OperatorToken, value: String, admin: User) {
        let (admin, _) = try await app.makeUser(email: "boss@example.com", role: .admin)
        let value = OperatorToken.generateToken()
        let token = OperatorToken(
            name: "alley-ops",
            tokenHash: OperatorToken.hash(token: value),
            createdByID: try admin.requireID()
        )
        try await token.save(on: app.db)
        return (token, value, admin)
    }

    /// 멀티파트 본문. CI 가 `curl -F` 로 보내는 모양이다.
    private func multipart(version: String, zip: Data) -> (HTTPHeaders, ByteBuffer, String) {
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
            "Content-Disposition: form-data; name=\"bundle\"; filename=\"alley-worker.zip\"\r\n"
        )
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zip)
        body.writeString("\r\n--\(boundary)--\r\n")
        return (headers, body, boundary)
    }

    // MARK: - 인증

    @Test("토큰 없이는 못 올린다")
    func requiresToken() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.POST, APIPath.operatorWorkerReleases) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    /// **잘못 넣은 토큰을 알아보게 한다.** 값만 보고 종류를 알 수 있는데
    /// "올바르지 않습니다" 로 끝내면 설정 파일을 한참 들여다보게 된다.
    @Test("배포 토큰을 넣으면 그렇다고 말한다")
    func namesTheWrongTokenKind() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(
                .POST,
                APIPath.operatorWorkerReleases,
                headers: .bearer(DeployToken.generateToken())
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.string.contains("배포 토큰"))
                #expect(response.body.string.contains("운영 토큰"))
            }
        }
    }

    @Test("폐기된 토큰은 통하지 않는다")
    func revokedTokenFails() async throws {
        try await withMigratedApp { app in
            let (token, value, _) = try await issueToken(on: app)
            token.revokedAt = Date()
            try await token.save(on: app.db)

            try await app.testing().test(
                .POST, APIPath.operatorWorkerReleases, headers: .bearer(value)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    /// 워커가 자기 다음 버전을 올릴 수 있게 되면 ADR-0042 가 사람을 끼워둔 자리가
    /// 사라진다.
    @Test("워커 토큰으로는 올릴 수 없다")
    func workerTokenCannotPublish() async throws {
        try await withMigratedApp { app in
            let (_, workerToken) = try await app.makeWorker(name: "cook")

            try await app.testing().test(
                .POST, APIPath.operatorWorkerReleases, headers: .bearer(workerToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    // MARK: - 올리기

    @Test("올리면 배포 중이 된다")
    func uploadsAndDeploys() async throws {
        try await withMigratedApp { app in
            _ = app.useFakeStorage()
            let (_, value, _) = try await issueToken(on: app)
            let (headers, body, _) = multipart(
                version: "0.3.0", zip: ZipFixture.workerBundle()
            )
            var withAuth = headers
            withAuth.bearerAuthorization = .init(token: value)

            try await app.testing().test(
                .POST, APIPath.operatorWorkerReleases, headers: withAuth, body: body
            ) { response in
                #expect(response.status == .created)
                let dto = try response.content.decode(WorkerReleaseSummaryDTO.self)
                #expect(dto.version == "0.3.0")
                #expect(dto.isCurrent)
            }

            let current = try #require(try await WorkerRelease.current(on: app.db))
            #expect(current.version == "0.3.0")
        }
    }

    /// 설치 키트를 잘못 올리는 일이 흔하다. 그것도 zip 이라 예전에는 통과했다.
    @Test("설치 키트를 올리면 거절한다")
    func rejectsKitZip() async throws {
        try await withMigratedApp { app in
            _ = app.useFakeStorage()
            let (_, value, _) = try await issueToken(on: app)
            let kit = ZipFixture.zip(names: [
                "kit/", "kit/install-worker.sh", "kit/alley-worker.app/Contents/Info.plist",
            ])
            let (headers, body, _) = multipart(version: "0.3.0", zip: kit)
            var withAuth = headers
            withAuth.bearerAuthorization = .init(token: value)

            try await app.testing().test(
                .POST, APIPath.operatorWorkerReleases, headers: withAuth, body: body
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("설치 키트"))
            }
        }
    }

    /// 파이프라인이 재실행되면 같은 버전을 다시 올린다. 그때 409 가 나는데,
    /// 목록을 미리 볼 수 있어야 "이미 됐다" 와 "실패" 를 구분할 수 있다.
    @Test("올려둔 목록을 볼 수 있다")
    func listsReleases() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (_, value, admin) = try await issueToken(on: app)
            _ = try await WorkerReleaseService.accept(
                version: "0.3.0",
                data: ZipFixture.workerBundle(),
                makeCurrent: true,
                by: admin,
                storage: storage,
                on: app.db,
                logger: app.logger
            )

            try await app.testing().test(
                .GET, APIPath.operatorWorkerReleases, headers: .bearer(value)
            ) { response in
                #expect(response.status == .ok)
                let rows = try response.content.decode([WorkerReleaseSummaryDTO].self)
                #expect(rows.count == 1)
                #expect(rows[0].version == "0.3.0")
                #expect(rows[0].isCurrent)
            }
        }
    }

    @Test("쓰면 마지막 사용 시각이 남는다")
    func recordsLastUsed() async throws {
        try await withMigratedApp { app in
            _ = app.useFakeStorage()
            let (token, value, _) = try await issueToken(on: app)
            #expect(token.lastUsedAt == nil)

            try await app.testing().test(
                .GET, APIPath.operatorWorkerReleases, headers: .bearer(value)
            ) { #expect($0.status == .ok) }

            let stored = try #require(
                try await OperatorToken.find(try token.requireID(), on: app.db)
            )
            #expect(stored.lastUsedAt != nil)
        }
    }
}
