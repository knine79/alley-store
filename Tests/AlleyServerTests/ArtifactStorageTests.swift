import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

@Suite("아티팩트 스토리지 주소")
struct ArtifactStorageTests {
    private func config(
        endpoint: String? = nil,
        publicEndpoint: String? = nil,
        usePathStyle: Bool = true,
        bucket: String = "alley-artifacts",
        region: String = "us-east-1",
        keyPrefix: String = ""
    ) -> AppConfig.StorageConfig {
        AppConfig.StorageConfig(
            endpoint: endpoint,
            publicEndpoint: publicEndpoint,
            region: region,
            bucket: bucket,
            keyPrefix: keyPrefix,
            accessKeyID: "key",
            secretAccessKey: "secret",
            usePathStyle: usePathStyle,
            presignedURLTTL: 900
        )
    }

    @Test("오브젝트 키에 앱과 버전이 드러난다")
    func objectKeyIsHierarchical() {
        let appID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        let versionID = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

        let key = ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .unsigned)
        #expect(key == "apps/\(appID.uuidString)/versions/\(versionID.uuidString)/unsigned.zip")
    }

    @Test("서명본과 미서명본은 다른 자리에 놓인다")
    func signedAndUnsignedDoNotCollide() {
        let appID = UUID()
        let versionID = UUID()

        let unsigned = ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .unsigned)
        let signed = ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .signed)

        // 워커가 서명본을 올릴 때 원본을 덮어쓰면 실패했을 때 되돌릴 수 없다.
        #expect(unsigned != signed)
    }

    @Test("path style 은 버킷을 경로에 넣는다")
    func pathStylePutsBucketInPath() throws {
        let url = try ArtifactStorage.objectBase(
            config: config(endpoint: "http://minio:9000", usePathStyle: true)
        )
        #expect(url.absoluteString == "http://minio:9000/alley-artifacts")
    }

    @Test("가상 호스트 방식은 버킷을 호스트에 넣는다")
    func virtualHostPutsBucketInHost() throws {
        let url = try ArtifactStorage.objectBase(
            config: config(endpoint: "https://storage.example.com", usePathStyle: false)
        )
        #expect(url.absoluteString == "https://alley-artifacts.storage.example.com")
    }

    @Test("엔드포인트가 없으면 AWS S3 주소를 만든다")
    func fallsBackToAWSEndpoint() throws {
        let url = try ArtifactStorage.objectBase(config: config(region: "ap-northeast-2"))
        #expect(url.absoluteString == "https://alley-artifacts.s3.ap-northeast-2.amazonaws.com")
    }

    @Test("빈 문자열 엔드포인트는 없는 것으로 본다")
    func treatsEmptyEndpointAsUnset() throws {
        // .env 에서 항목만 남기고 값을 비우는 일이 흔하다.
        // 이걸 엔드포인트로 받으면 스킴 없는 URL 이 되어 서명이 엉뚱한 곳을 가리킨다.
        let url = try ArtifactStorage.objectBase(config: config(endpoint: ""))
        #expect(url.absoluteString == "https://alley-artifacts.s3.us-east-1.amazonaws.com")
    }

    @Test("해석할 수 없는 엔드포인트는 기동 시점에 걸러진다")
    func rejectsMalformedEndpoint() {
        #expect(throws: ArtifactStorage.StorageError.self) {
            try ArtifactStorage.objectBase(config: config(endpoint: "이건 URL 이 아니다"))
        }
    }

    // MARK: - 공개 주소

    @Test("공개 주소를 주면 그쪽으로 서명한다")
    func publicEndpointWinsForSigning() throws {
        // 서명은 호스트를 포함해서 계산된다. 서버가 붙는 내부 주소로 서명해서 내주면
        // 클라이언트가 받는 순간 서명이 맞지 않아 403 이 난다.
        let url = try ArtifactStorage.objectBase(
            config: config(
                endpoint: "http://minio:9000",
                publicEndpoint: "https://storage.example.com"
            )
        )
        #expect(url.absoluteString == "https://storage.example.com/alley-artifacts")
    }

    @Test("공개 주소를 안 주면 내부 주소를 그대로 쓴다")
    func fallsBackToInternalEndpoint() throws {
        // 로컬 개발은 서버와 브라우저가 같은 주소로 스토리지에 닿는다. 나눌 이유가 없다.
        let url = try ArtifactStorage.objectBase(config: config(endpoint: "http://localhost:9000"))
        #expect(url.absoluteString == "http://localhost:9000/alley-artifacts")
    }

    @Test("빈 문자열 공개 주소는 없는 것으로 본다")
    func treatsEmptyPublicEndpointAsUnset() throws {
        let url = try ArtifactStorage.objectBase(
            config: config(endpoint: "http://minio:9000", publicEndpoint: "")
        )
        #expect(url.absoluteString == "http://minio:9000/alley-artifacts")
    }

    @Test("공개 주소만 주면 그것으로 만든다")
    func publicEndpointAloneIsEnough() throws {
        let url = try ArtifactStorage.objectBase(
            config: config(publicEndpoint: "https://storage.example.com", usePathStyle: false)
        )
        #expect(url.absoluteString == "https://alley-artifacts.storage.example.com")
    }

    // MARK: - 키 프리픽스

    @Test("프리픽스가 없으면 키가 그대로다")
    func noPrefixLeavesKeyAlone() throws {
        let storage = FakeArtifactStorage()
        #expect(storage.newKey("apps/a/versions/b/signed.zip") == "apps/a/versions/b/signed.zip")
    }

    @Test("프리픽스가 있으면 키 앞에 붙는다")
    func prefixGoesInFront() throws {
        let storage = FakeArtifactStorage(keyPrefix: "proj-abc123")
        #expect(storage.newKey("apps/a/signed.zip") == "proj-abc123/apps/a/signed.zip")
        #expect(storage.newKey("feedback/f/screenshot") == "proj-abc123/feedback/f/screenshot")
    }

    @Test("슬래시를 어떻게 적어도 같은 결과가 된다", arguments: [
        "proj-abc123", "proj-abc123/", "/proj-abc123/", "  /proj-abc123/  ",
    ])
    func prefixSlashesAreNormalized(_ raw: String) throws {
        let config = try TestSupport.config(overrides: ["S3_KEY_PREFIX": raw])
        #expect(config.storage.keyPrefix == "proj-abc123")
    }

    @Test("프리픽스를 안 주거나 슬래시만 주면 없는 것으로 본다", arguments: ["", "/", "   "])
    func blankPrefixIsUnset(_ raw: String) throws {
        let config = try TestSupport.config(overrides: ["S3_KEY_PREFIX": raw])
        #expect(config.storage.keyPrefix.isEmpty)
    }

    // MARK: - 액세스 키

    @Test("액세스 키를 둘 다 비우면 기본 자격증명 체인에 맡긴다")
    func credentialsMayBeAbsent() throws {
        let config = try TestSupport.config(
            overrides: ["S3_ACCESS_KEY_ID": "", "S3_SECRET_ACCESS_KEY": ""]
        )
        #expect(config.storage.accessKeyID == nil)
        #expect(config.storage.secretAccessKey == nil)
    }

    @Test("액세스 키를 하나만 주면 기동을 막는다", arguments: [
        "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY",
    ])
    func halfConfiguredCredentialsFailToBoot(_ blanked: String) {
        // 그대로 뜨면 기본 체인으로 조용히 넘어가서, 방금 넣은 키가 왜 안 먹는지
        // 아무도 모르게 된다.
        #expect(throws: AppConfig.LoadError.self) {
            try TestSupport.config(overrides: [blanked: ""])
        }
    }

    @Test("업로드 방식이 아티팩트 종류로 이어진다", arguments: [
        (UploadKind.unsigned, ArtifactKind.unsigned),
        (UploadKind.signed, ArtifactKind.signed),
    ])
    func uploadKindMapsToArtifactKind(_ upload: UploadKind, _ expected: ArtifactKind) {
        #expect(upload.artifactKind == expected)
    }
}

/// 프리픽스가 실제 업로드 경로 끝까지 따라가는지.
///
/// 단위 테스트로 `newKey` 만 확인하면, 어느 한 호출부가 프리픽스를 안 붙여도 통과한다.
/// 여기서는 버전을 만들고 완료 통지까지 보내서 데이터베이스에 남는 키를 본다.
@Suite("키 프리픽스가 붙은 업로드")
struct PrefixedUploadTests {
    private func seedApp(on app: Application) async throws -> (appID: UUID, token: String) {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        return (try record.requireID(), token)
    }

    /// 버전을 만들고 올렸다고 통지한 뒤, 아티팩트 행에 남은 키를 돌려준다.
    private func upload(
        on app: Application,
        storage: FakeArtifactStorage,
        keyBuilder: (UUID, UUID) -> String
    ) async throws -> String {
        let setup = try await seedApp(on: app)

        var versionID: UUID?
        try await app.testing().test(
            .POST, APIPath.versions(ofApp: setup.appID), headers: .bearer(setup.token),
            beforeRequest: {
                try $0.content.encode(CreateVersionRequest(shortVersion: "1.0.0", buildNumber: 1))
            }
        ) { response in
            #expect(response.status == .created)
            versionID = try response.content.decode(UploadTicket.self).version.id
        }

        let id = try #require(versionID)
        // 클라이언트가 presigned URL 로 올렸다고 가정한다.
        storage.place(key: keyBuilder(setup.appID, id), size: 2048)

        try await app.testing().test(
            .POST, APIPath.completeUpload(versionID: id), headers: .bearer(setup.token),
            beforeRequest: { try $0.content.encode(CompleteUploadRequest(sha256: "abc")) }
        ) { #expect($0.status == .ok) }

        let artifact = try #require(
            try await Artifact.query(on: app.db).filter(\.$version.$id == id).first()
        )
        return artifact.storageKey
    }

    @Test("프리픽스를 주면 오브젝트가 그 아래에 놓인다")
    func objectsLandUnderPrefix() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage(keyPrefix: "proj-abc123")
            let stored = try await upload(on: app, storage: storage) { appID, versionID in
                "proj-abc123/"
                    + ArtifactStorage.objectKey(
                        appID: appID, versionID: versionID, kind: .unsigned
                    )
            }
            #expect(stored.hasPrefix("proj-abc123/apps/"))
        }
    }

    @Test("프리픽스가 없으면 예전 자리 그대로다")
    func objectsStayAtRootWithoutPrefix() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let stored = try await upload(on: app, storage: storage) { appID, versionID in
                ArtifactStorage.objectKey(appID: appID, versionID: versionID, kind: .unsigned)
            }
            #expect(stored.hasPrefix("apps/"))
        }
    }

    @Test("프리픽스가 생겨도 이미 저장된 키는 그대로 쓴다")
    func existingKeysAreUsedVerbatim() async throws {
        // 프리픽스를 나중에 켜면 기존 행이 가리키는 오브젝트는 원래 자리에 그대로 있다.
        // 저장된 값이 곧 전체 키라서, 여기에 프리픽스를 덧붙이면 못 찾는다.
        try await withMigratedApp { app in
            let storage = app.useFakeStorage(keyPrefix: "proj-abc123")
            let (owner, token) = try await app.makeUser(
                email: "dev@example.com", role: .developer
            )
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let version = try await app.seedVersion(
                appID: try record.requireID(), short: "1.0.0", build: 1, state: .released, by: owner
            )
            let legacyKey = "apps/legacy/versions/legacy/signed.zip"
            try await Artifact(
                versionID: try version.requireID(), kind: .signed,
                storageKey: legacyKey, sha256: "abc", fileSize: 1024
            ).save(on: app.db)
            storage.place(key: legacyKey, size: 1024)

            try await app.testing().test(
                .GET, APIPath.download(versionID: try version.requireID()),
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .ok)
                let ticket = try response.content.decode(DownloadTicket.self)
                #expect(ticket.downloadURL.contains(legacyKey))
                #expect(!ticket.downloadURL.contains("proj-abc123"))
            }
        }
    }
}
