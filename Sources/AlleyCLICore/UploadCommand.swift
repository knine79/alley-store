import AlleyShared
import Crypto
import Foundation

/// `alley upload` 가 하는 일.
///
/// 웹 콘솔의 업로드 화면과 같은 세 단계를 밟는다. 버전을 만들고, presigned URL 로
/// 올리고, 다 올렸다고 알린다. 다른 점은 해시를 계산해서 보낸다는 것이다. CI 는
/// 파일이 디스크에 있고 메모리 제약도 브라우저만큼 빡빡하지 않다 (ADR-0012 후속).
public struct UploadCommand: Sendable {
    public struct Options: Sendable {
        public var file: URL
        public var shortVersion: String
        /// 비우면 서버의 마지막 빌드 번호에 1을 더한다.
        public var buildNumber: Int?
        public var releaseNotes: String?
        public var minimumOSVersion: String?
        public var uploadKind: UploadKind
        /// 서명할 때 붙일 entitlements plist 의 XML 원문 (ADR-0020).
        ///
        /// 파일을 읽는 것은 인자 파싱 쪽이 한다. 파일이 없거나 plist 가 아닌 것은
        /// 서버에 붙기 전에 걸러야 할 인자 실수다.
        public var entitlements: String?
        /// 올린 뒤 곧바로 출시할지. 미서명 업로드는 서명이 끝나야 하므로 쓸 수 없다.
        public var releaseAfterUpload: Bool
        /// 토큰이 가리키는 앱이 이것인지 확인한다. 파이프라인에 엉뚱한 토큰이
        /// 들어갔을 때 업로드가 끝난 뒤가 아니라 시작하기 전에 걸린다.
        public var expectedBundleID: String?

        public init(
            file: URL,
            shortVersion: String,
            buildNumber: Int? = nil,
            releaseNotes: String? = nil,
            minimumOSVersion: String? = nil,
            uploadKind: UploadKind = .unsigned,
            entitlements: String? = nil,
            releaseAfterUpload: Bool = false,
            expectedBundleID: String? = nil
        ) {
            self.file = file
            self.shortVersion = shortVersion
            self.buildNumber = buildNumber
            self.releaseNotes = releaseNotes
            self.minimumOSVersion = minimumOSVersion
            self.uploadKind = uploadKind
            self.entitlements = entitlements
            self.releaseAfterUpload = releaseAfterUpload
            self.expectedBundleID = expectedBundleID
        }
    }

    public enum UploadError: Error, CustomStringConvertible {
        case fileMissing(URL)
        case bundleIDMismatch(expected: String, actual: String)
        case cannotReleaseUnsigned

        public var description: String {
            switch self {
            case .fileMissing(let url):
                return "올릴 파일이 없습니다: \(url.path)"
            case .bundleIDMismatch(let expected, let actual):
                return """
                    이 토큰은 \(actual) 의 것인데 \(expected) 를 올리려 했습니다. \
                    파이프라인의 ALLEY_TOKEN 이 맞는지 확인하세요.
                    """
            case .cannotReleaseUnsigned:
                return """
                    미서명으로 올린 버전은 바로 출시할 수 없습니다. 서명 워커가 끝낸 뒤 \
                    웹 콘솔에서 출시하거나, 이미 서명·공증을 마쳤다면 --signed 로 올리세요.
                    """
            }
        }
    }

    private let api: StoreAPI
    private let log: @Sendable (String) -> Void

    public init(api: StoreAPI, log: @escaping @Sendable (String) -> Void) {
        self.api = api
        self.log = log
    }

    @discardableResult
    public func run(_ options: Options) async throws -> VersionDTO {
        guard FileManager.default.fileExists(atPath: options.file.path) else {
            throw UploadError.fileMissing(options.file)
        }
        if options.releaseAfterUpload, options.uploadKind == .unsigned {
            throw UploadError.cannotReleaseUnsigned
        }

        let app = try await api.currentApp()
        if let expected = options.expectedBundleID, expected != app.bundleID {
            throw UploadError.bundleIDMismatch(expected: expected, actual: app.bundleID)
        }
        log("앱: \(app.name) (\(app.bundleID))")

        // `??` 의 오른쪽은 autoclosure 라 await 를 넣을 수 없다. 풀어서 쓴다.
        let build: Int
        if let given = options.buildNumber {
            build = given
        } else {
            build = try await nextBuildNumber(ofApp: app.id)
        }
        log("버전 \(options.shortVersion) (빌드 \(build)) 를 만듭니다...")

        let ticket = try await api.createVersion(
            CreateVersionRequest(
                shortVersion: options.shortVersion,
                buildNumber: build,
                releaseNotes: options.releaseNotes,
                minimumOSVersion: options.minimumOSVersion,
                uploadKind: options.uploadKind,
                entitlements: options.entitlements
            ),
            ofApp: app.id
        )

        log("올리는 중: \(options.file.lastPathComponent)")
        try await api.upload(options.file, to: ticket.uploadURL)

        let digest = try Self.sha256(of: options.file)
        var version = try await api.completeUpload(
            versionID: ticket.version.id,
            sha256: digest
        )
        log("올렸습니다. 상태: \(version.state.displayName)")

        if options.releaseAfterUpload {
            version = try await api.release(versionID: version.id)
            log("출시했습니다.")
        } else if version.state == .uploaded {
            log("서명 워커가 이어받습니다. 진행 상황은 웹 콘솔에서 볼 수 있습니다.")
        }
        return version
    }

    /// 서버가 아는 마지막 빌드 번호에 1을 더한다.
    ///
    /// CI 가 빌드 번호를 따로 세지 않아도 되게 한다. 겹치면 서버가 거절하므로
    /// 여기서 틀려도 조용히 잘못되지는 않는다.
    private func nextBuildNumber(ofApp id: UUID) async throws -> Int {
        let versions = try await api.versions(ofApp: id)
        return (versions.map(\.buildNumber).max() ?? 0) + 1
    }

    /// 파일의 SHA-256 을 16진수 소문자로.
    ///
    /// 조각내어 읽는다. 수백 MB 짜리 앱을 통째로 메모리에 올릴 이유가 없다.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
