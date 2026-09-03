import AlleyShared
import Foundation
import SotoS3
import Vapor

/// 만료 시각이 붙은 서명된 URL.
public struct PresignedURL: Sendable {
    public var url: String
    public var expiresAt: Date

    public init(url: String, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// 아티팩트를 어디에 두고 어떻게 주고받을지.
///
/// 프로토콜로 한 겹 두는 이유는 테스트 때문이다. 업로드 완료 통지와 서명 결과 보고는
/// **스토리지에 파일이 실제로 있는지 확인하는 것이 핵심 규칙**인데, 구현이 S3 에
/// 박혀 있으면 그 규칙을 검증하려고 매번 오브젝트 스토리지를 띄워야 한다.
public protocol ArtifactStoring: Sendable {
    /// 이 스토리지가 **새로 만드는** 키 앞에 붙는 자리. 앞뒤 슬래시 없이. 없으면 빈 문자열.
    var keyPrefix: String { get }

    /// 이 키로 파일을 올릴 수 있는 URL. `PUT` 으로 보낸다.
    func uploadURL(key: String) async throws -> PresignedURL
    /// 이 키의 파일을 받을 수 있는 URL. `GET` 으로 보낸다.
    func downloadURL(key: String) async throws -> PresignedURL
    /// 스토리지에 실제로 파일이 있는지 확인하고 크기를 읽는다. 없으면 nil.
    func head(key: String) async throws -> Int64?

    /// 작은 파일을 서버가 직접 올린다.
    ///
    /// **앱 바이너리에는 쓰지 않는다.** 그건 presigned URL 로 클라이언트가 직접
    /// 올린다(ADR-0009). 이 경로는 피드백 스크린샷처럼 수 MB 짜리 파일용이다.
    /// 왜 예외를 두었는지는 ADR-0016 에 있다.
    func put(_ data: Data, to key: String, contentType: String?) async throws

    func delete(key: String) async throws
}

extension ArtifactStoring {
    /// 프리픽스를 안 쓰는 것이 기본이다. 테스트용 가짜가 이걸 신경 쓸 필요는 없다.
    public var keyPrefix: String { "" }

    /// **새로** 만드는 오브젝트가 놓일 자리를 정한다.
    ///
    /// 이미 `artifacts.storage_key` 나 `feedbacks.screenshot_key` 에 적혀 있는 키에는
    /// 쓰지 않는다. 저장된 값이 곧 전체 키다. 프리픽스가 나중에 생기거나 바뀌어도
    /// 그 행들이 가리키는 오브젝트는 원래 자리에 그대로 있고, 그래야 읽을 수 있다.
    public func newKey(_ logicalKey: String) -> String {
        keyPrefix.isEmpty ? logicalKey : "\(keyPrefix)/\(logicalKey)"
    }
}

/// S3 호환 오브젝트 스토리지 구현.
///
/// 서버는 바이너리를 대신 받아주지 않는다. 만료 있는 URL 을 내주고 클라이언트가
/// 스토리지와 직접 주고받게 한다. 수백 MB 짜리 앱이 서버 메모리와 대역폭을
/// 거쳐가면 서버가 병목이 되고, 재시도할 때마다 그 비용을 다시 낸다.
public struct ArtifactStorage: ArtifactStoring {
    public enum StorageError: Error, CustomStringConvertible {
        case invalidEndpoint(String)
        case objectMissing(key: String)

        public var description: String {
            switch self {
            case .invalidEndpoint(let value):
                return "스토리지 엔드포인트를 URL 로 해석할 수 없습니다: \(value)"
            case .objectMissing(let key):
                return "스토리지에 파일이 없습니다: \(key)"
            }
        }
    }

    private let s3: S3
    private let bucket: String
    private let ttl: TimeInterval
    /// 오브젝트 URL 을 만드는 기준. presigned URL 은 이 위에 서명을 얹는다.
    private let objectBase: URL

    public let keyPrefix: String

    public init(client: AWSClient, config: AppConfig.StorageConfig) throws {
        self.bucket = config.bucket
        self.ttl = TimeInterval(config.presignedURLTTL)
        self.keyPrefix = config.keyPrefix

        self.s3 = S3(
            client: client,
            region: .init(rawValue: config.region),
            endpoint: config.endpoint.flatMap { $0.isEmpty ? nil : $0 },
            // Soto 는 기본이 path style 이고, 가상 호스트 방식은 옵트인이다.
            // MinIO 는 path style 만 쓴다.
            options: config.usePathStyle ? [] : [.s3ForceVirtualHost]
        )
        self.objectBase = try Self.objectBase(config: config)
    }

    /// 버킷 안에서 파일이 놓이는 자리.
    ///
    /// 앱과 버전 ID 로 계층을 나눠서 사람이 콘솔에서 봐도 어느 앱의 무엇인지 알 수 있게 한다.
    /// 확장자를 `.zip` 으로 고정하는 이유는 `.app` 번들이 디렉터리라서 그대로는 못 올리기 때문이다.
    public static func objectKey(appID: UUID, versionID: UUID, kind: ArtifactKind) -> String {
        "apps/\(appID.uuidString)/versions/\(versionID.uuidString)/\(kind.rawValue).zip"
    }

    public func uploadURL(key: String) async throws -> PresignedURL {
        try await sign(key: key, method: .PUT)
    }

    public func downloadURL(key: String) async throws -> PresignedURL {
        try await sign(key: key, method: .GET)
    }

    /// 클라이언트가 "다 올렸다"고 말하는 것만 믿으면 빈 버전이 출시될 수 있다.
    /// 접근 실패는 그대로 던진다.
    public func head(key: String) async throws -> Int64? {
        do {
            let output = try await s3.headObject(.init(bucket: bucket, key: key))
            return output.contentLength
        } catch let error as S3ErrorType where error == .notFound {
            return nil
        } catch let error as AWSRawError where error.context.responseCode == .notFound {
            // MinIO 는 HEAD 응답에 본문이 없어서 타입이 붙은 오류로 안 올 때가 있다.
            return nil
        }
    }

    public func put(_ data: Data, to key: String, contentType: String?) async throws {
        _ = try await s3.putObject(
            .init(
                body: .init(bytes: data),
                bucket: bucket,
                contentType: contentType,
                key: key
            )
        )
    }

    public func delete(key: String) async throws {
        _ = try await s3.deleteObject(.init(bucket: bucket, key: key))
    }

    private func sign(key: String, method: HTTPMethod) async throws -> PresignedURL {
        let url = objectBase.appendingPathComponent(key)
        let signed = try await s3.signURL(
            url: url,
            httpMethod: method,
            expires: .seconds(Int64(ttl))
        )
        return PresignedURL(url: signed.absoluteString, expiresAt: Date().addingTimeInterval(ttl))
    }

    /// `{엔드포인트}/{버킷}` 또는 `https://{버킷}.s3.{리전}.amazonaws.com` 을 만든다.
    ///
    /// presigned URL 은 이 URL 위에 서명을 얹는 것이라, 여기가 틀리면 서명은 맞는데
    /// 엉뚱한 곳을 가리키는 URL 이 나간다. 테스트에서 직접 확인할 수 있게 열어둔다.
    static func objectBase(config: AppConfig.StorageConfig) throws -> URL {
        guard let endpoint = config.endpoint.flatMap({ $0.isEmpty ? nil : $0 }) else {
            // 엔드포인트를 안 주면 AWS S3 로 본다.
            guard let url = URL(string: "https://\(config.bucket).s3.\(config.region).amazonaws.com") else {
                throw StorageError.invalidEndpoint(config.region)
            }
            return url
        }

        guard var components = URLComponents(string: endpoint), let host = components.host else {
            throw StorageError.invalidEndpoint(endpoint)
        }

        if config.usePathStyle {
            components.path = "/\(config.bucket)"
        } else {
            components.host = "\(config.bucket).\(host)"
        }

        guard let url = components.url else {
            throw StorageError.invalidEndpoint(endpoint)
        }
        return url
    }
}

// MARK: - Vapor 연동

extension Application {
    private struct ArtifactStorageKey: StorageKey {
        typealias Value = any ArtifactStoring
    }

    public internal(set) var artifactStorage: any ArtifactStoring {
        get {
            guard let storage = storage[ArtifactStorageKey.self] else {
                fatalError("ArtifactStorage 가 설정되기 전에 접근했습니다. configure(_:) 를 먼저 호출하세요.")
            }
            return storage
        }
        set { storage[ArtifactStorageKey.self] = newValue }
    }
}

extension Request {
    public var artifactStorage: any ArtifactStoring {
        application.artifactStorage
    }
}

/// `AWSClient` 는 쓰고 나서 반드시 닫아야 한다. 안 닫으면 `deinit` 에서 죽는다.
struct AWSClientLifecycle: LifecycleHandler {
    let client: AWSClient

    func shutdownAsync(_ application: Application) async {
        do {
            try await client.shutdown()
        } catch {
            application.logger.warning("AWS 클라이언트 종료 실패: \(error)")
        }
    }
}
