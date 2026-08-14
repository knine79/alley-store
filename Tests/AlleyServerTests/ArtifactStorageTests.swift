import AlleyShared
import Foundation
import Testing

@testable import AlleyServer

@Suite("아티팩트 스토리지 주소")
struct ArtifactStorageTests {
    private func config(
        endpoint: String? = nil,
        usePathStyle: Bool = true,
        bucket: String = "alley-artifacts",
        region: String = "us-east-1"
    ) -> AppConfig.StorageConfig {
        AppConfig.StorageConfig(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
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

    @Test("업로드 방식이 아티팩트 종류로 이어진다", arguments: [
        (UploadKind.unsigned, ArtifactKind.unsigned),
        (UploadKind.signed, ArtifactKind.signed),
    ])
    func uploadKindMapsToArtifactKind(_ upload: UploadKind, _ expected: ArtifactKind) {
        #expect(upload.artifactKind == expected)
    }
}
