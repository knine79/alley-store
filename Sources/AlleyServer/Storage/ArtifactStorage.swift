import AlleyShared
import Foundation
import SotoS3
import Vapor

/// 아티팩트 오브젝트 스토리지 접근.
///
/// 서버는 바이너리를 대신 받아주지 않는다. 만료 있는 URL 을 내주고 클라이언트가
/// 스토리지와 직접 주고받게 한다. 수백 MB 짜리 앱이 서버 메모리와 대역폭을
/// 거쳐가면 서버가 병목이 되고, 재시도할 때마다 그 비용을 다시 낸다.
public struct ArtifactStorage: Sendable {
    /// 만료 시각이 붙은 서명된 URL.
    public struct Presigned: Sendable {
        public var url: String
        public var expiresAt: Date
    }

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

    public init(client: AWSClient, config: AppConfig.StorageConfig) throws {
        self.bucket = config.bucket
        self.ttl = TimeInterval(config.presignedURLTTL)

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

    /// 이 키로 파일을 올릴 수 있는 URL. `PUT` 으로 보낸다.
    public func uploadURL(key: String) async throws -> Presigned {
        try await sign(key: key, method: .PUT)
    }

    /// 이 키의 파일을 받을 수 있는 URL. `GET` 으로 보낸다.
    public func downloadURL(key: String) async throws -> Presigned {
        try await sign(key: key, method: .GET)
    }

    /// 스토리지에 실제로 파일이 있는지 확인하고 크기를 읽는다.
    ///
    /// 클라이언트가 "다 올렸다"고 말하는 것만 믿으면 빈 버전이 출시될 수 있다.
    /// 없으면 nil 을 준다. 접근 실패는 그대로 던진다.
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

    private func sign(key: String, method: HTTPMethod) async throws -> Presigned {
        let url = objectBase.appendingPathComponent(key)
        let signed = try await s3.signURL(
            url: url,
            httpMethod: method,
            expires: .seconds(Int64(ttl))
        )
        return Presigned(url: signed.absoluteString, expiresAt: Date().addingTimeInterval(ttl))
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
        typealias Value = ArtifactStorage
    }

    public internal(set) var artifactStorage: ArtifactStorage {
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
    public var artifactStorage: ArtifactStorage {
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
