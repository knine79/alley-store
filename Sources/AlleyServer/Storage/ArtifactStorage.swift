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

    /// 받는 쪽에 보일 파일 이름을 정해서 내준다.
    ///
    /// **오브젝트 키가 곧 파일 이름이 된다.** 키는 `.../unsigned.zip` 처럼 우리
    /// 사정에 맞춰 지은 이름이라, 그대로 나가면 받은 사람의 내려받기 폴더에
    /// `unsigned.zip` 이 쌓인다. 무엇을 받았는지 알 수 없고, 여러 번 받으면
    /// `unsigned (3).zip` 이 된다.
    func downloadURL(key: String, filename: String?) async throws -> PresignedURL
    /// 스토리지에 실제로 파일이 있는지 확인하고 크기를 읽는다. 없으면 nil.
    func head(key: String) async throws -> Int64?

    /// 작은 파일을 서버가 직접 올린다.
    ///
    /// **앱 바이너리에는 쓰지 않는다.** 그건 presigned URL 로 클라이언트가 직접
    /// 올린다(ADR-0009). 이 경로는 피드백 스크린샷처럼 수 MB 짜리 파일용이다.
    /// 왜 예외를 두었는지는 ADR-0016 에 있다.
    func put(_ data: Data, to key: String, contentType: String?) async throws

    /// 스토리지에 있는 파일을 서버가 직접 읽는다.
    ///
    /// 두 자리에서 쓴다. 브랜딩 이미지를 화면에 내줄 때, 그리고 스토어 앱 번들을
    /// 다시 쌀 때다. 둘 다 서버가 **내용을 알아야** 하는 경우라 presigned URL 로는
    /// 대신할 수 없다.
    ///
    /// - Parameter limit: 이 바이트 수를 넘으면 읽지 않고 실패한다. 호출하는 쪽이
    ///   자기가 다룰 수 있는 크기를 안다. 상한 없이 읽으면 잘못 올라온 파일 하나로
    ///   서버 메모리가 넘어간다.
    func get(key: String, limit: Int) async throws -> Data

    func delete(key: String) async throws
}

extension ArtifactStoring {
    /// 이름을 정하지 않으면 지금까지와 같다. 스토리지가 키에서 짐작한다.
    public func downloadURL(key: String) async throws -> PresignedURL {
        try await downloadURL(key: key, filename: nil)
    }

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
        case noCredentials
        case tooLarge(key: String, limit: Int)

        public var description: String {
            switch self {
            case .invalidEndpoint(let value):
                return "스토리지 엔드포인트를 URL 로 해석할 수 없습니다: \(value)"
            case .objectMissing(let key):
                return "스토리지에 파일이 없습니다: \(key)"
            case .tooLarge(let key, let limit):
                return "파일이 서버가 읽을 수 있는 크기(\(limit / 1024 / 1024)MB)를 넘습니다: \(key)"
            case .noCredentials:
                return """
                    스토리지 자격증명을 찾지 못했습니다. S3_ACCESS_KEY_ID 와 \
                    S3_SECRET_ACCESS_KEY 를 주거나, 인스턴스에 붙은 역할로 인증되도록 하세요. \
                    둘 다 비우면 SDK 기본 체인(AWS_* 환경변수, 웹 아이덴티티 토큰, \
                    인스턴스 메타데이터, ~/.aws)을 차례로 봅니다.
                    """
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
            // 여기는 **서버가** 붙는 주소다. 클라이언트에게 내주는 주소는 objectBase 쪽이다.
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
        // 확장자는 갈래가 정한다. dmg 를 `.zip` 으로 올려두면 받는 쪽이 zip 으로 알고
        // 풀려 들다가 실패한다 (ADR-0050).
        "apps/\(appID.uuidString)/versions/\(versionID.uuidString)/\(kind.rawValue).\(kind.fileExtension)"
    }

    public func uploadURL(key: String) async throws -> PresignedURL {
        try await sign(key: key, method: .PUT)
    }

    public func downloadURL(key: String, filename: String?) async throws -> PresignedURL {
        try await sign(key: key, method: .GET, filename: filename)
    }

    /// 클라이언트가 "다 올렸다"고 말하는 것만 믿으면 빈 버전이 출시될 수 있다.
    /// 접근 실패는 그대로 던진다.
    public func head(key: String) async throws -> Int64? {
        do {
            let output = try await explained { try await s3.headObject(.init(bucket: bucket, key: key)) }
            return output.contentLength
        } catch let error as S3ErrorType where error == .notFound {
            return nil
        } catch let error as AWSRawError where error.context.responseCode == .notFound {
            // MinIO 는 HEAD 응답에 본문이 없어서 타입이 붙은 오류로 안 올 때가 있다.
            return nil
        }
    }

    public func put(_ data: Data, to key: String, contentType: String?) async throws {
        _ = try await explained {
            try await s3.putObject(
                .init(
                    body: .init(bytes: data),
                    bucket: bucket,
                    contentType: contentType,
                    key: key
                )
            )
        }
    }

    public func get(key: String, limit: Int) async throws -> Data {
        let output = try await explained { try await s3.getObject(.init(bucket: bucket, key: key)) }

        // 상한을 넘으면 `collect` 가 던진다. 그 오류는 "너무 크다" 를 말해주지 않아서
        // 여기서 바꿔 준다. 이 실패는 사람이 잘못된 파일을 올려서 나는 것이라,
        // 무엇이 문제인지 화면까지 그대로 전해져야 한다.
        do {
            return Data(buffer: try await output.body.collect(upTo: limit))
        } catch {
            throw StorageError.tooLarge(key: key, limit: limit)
        }
    }

    public func delete(key: String) async throws {
        _ = try await explained { try await s3.deleteObject(.init(bucket: bucket, key: key)) }
    }

    private func sign(
        key: String,
        method: HTTPMethod,
        filename: String? = nil
    ) async throws -> PresignedURL {
        var url = objectBase.appendingPathComponent(key)

        // S3 와 minio 둘 다 이 질의 항목을 읽어 응답 헤더로 돌려준다. 서명에 포함되므로
        // 여기서 붙여야 하고, 받는 쪽이 고치면 서명이 깨진다.
        if let filename, let disposition = Self.contentDisposition(for: filename),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            components.queryItems = (components.queryItems ?? [])
                + [URLQueryItem(name: "response-content-disposition", value: disposition)]
            url = components.url ?? url
        }

        let signed = try await explained {
            try await s3.signURL(
                url: url,
                httpMethod: method,
                expires: .seconds(Int64(ttl))
            )
        }
        return PresignedURL(url: signed.absoluteString, expiresAt: Date().addingTimeInterval(ttl))
    }

    /// `Content-Disposition` 한 줄을 만든다. 쓸 수 없는 이름이면 nil 이고, 그때는
    /// 지금까지처럼 키에서 짐작한 이름으로 나간다.
    ///
    /// **두 벌을 싣는다.** `filename` 은 ASCII 로 접은 것이고, `filename*` 은 원래
    /// 이름을 RFC 5987 로 적은 것이다. 앱 이름에 한글이 흔한데 ASCII 만 실으면
    /// "----- 1.0.0.zip" 이 되고, 반대로 `filename*` 만 실으면 그것을 모르는 오래된
    /// 내려받기 도구가 이름을 통째로 버린다. 둘을 함께 싣는 것이 표준이 시키는 방식이고,
    /// 아는 쪽은 `filename*` 을 먼저 본다.
    static func contentDisposition(for filename: String) -> String? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ASCII 벌. 헤더 값에서 따옴표와 역슬래시가 구문을 깨므로 함께 걷어낸다.
        let asciiAllowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " .-_()"))
        var ascii = ""
        for scalar in trimmed.unicodeScalars {
            ascii.append(scalar.isASCII && asciiAllowed.contains(scalar) ? Character(scalar) : "-")
        }
        // 한글 이름은 전부 `-` 가 된다. 그 줄이 이름 노릇을 하지는 못해도 확장자는
        // 남아서, `filename*` 을 모르는 쪽이 최소한 무엇인지는 알 수 있다.
        ascii = ascii.trimmingCharacters(in: .whitespaces)
        guard !ascii.isEmpty else { return nil }

        // RFC 5987 벌.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return "attachment; filename=\"\(ascii)\""
        }
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    /// 자격증명을 못 찾았을 때의 실패를 알아볼 수 있는 말로 바꾼다.
    ///
    /// 기본 자격증명 체인은 아무것도 못 찾아도 기동을 막지 않는다. 체인 전체가 빈손이면
    /// Soto 가 그 자리에 "언제나 실패하는" 제공자를 놓고, 실패는 스토리지를 처음 쓰는
    /// 순간에야 `No credential provider found.` 한 줄로 나온다. 그 문장만 보고
    /// 무엇을 설정해야 하는지 알 수 있는 사람은 없다.
    private func explained<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CredentialProviderError where error == .noProvider {
            throw StorageError.noCredentials
        }
    }

    /// `{엔드포인트}/{버킷}` 또는 `https://{버킷}.s3.{리전}.amazonaws.com` 을 만든다.
    ///
    /// **공개 주소(`S3_PUBLIC_ENDPOINT`)가 있으면 그것으로 만든다.** 서명은 호스트를
    /// 포함해서 계산되므로, 여기가 클라이언트가 실제로 붙을 주소여야 한다. 서버가 붙는
    /// 내부 주소로 서명해서 내주면 스토리지가 403 으로 거절한다.
    ///
    /// 테스트에서 직접 확인할 수 있게 열어둔다.
    static func objectBase(config: AppConfig.StorageConfig) throws -> URL {
        guard let endpoint = config.presignEndpoint else {
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
