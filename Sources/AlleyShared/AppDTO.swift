import Foundation

/// 사용자 역할.
public enum UserRole: String, Codable, Sendable, CaseIterable {
    /// 앱을 다운로드하고 피드백을 남길 수 있다.
    case user
    /// 앱을 등록하고 버전을 올릴 수 있다.
    case developer
    /// 역할 관리, 워커 등록, 스토어 설정을 할 수 있다.
    case admin

    public var canPublish: Bool {
        self == .developer || self == .admin
    }

    public var canAdminister: Bool {
        self == .admin
    }
}

public struct UserDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var email: String
    public var name: String
    public var avatarURL: String?
    public var role: UserRole

    public init(id: UUID, email: String, name: String, avatarURL: String? = nil, role: UserRole) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.role = role
    }
}

public struct AppDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// 앱마다 고유해야 한다. macOS가 이 값으로 앱을 식별한다.
    public var bundleID: String
    public var name: String
    public var summary: String?
    public var description: String?
    public var iconURL: String?
    public var category: String?
    public var ownerID: UUID
    /// 현재 사내에 출시된 최신 버전. 아직 출시본이 없으면 nil.
    public var latestReleasedVersion: VersionDTO?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        bundleID: String,
        name: String,
        summary: String? = nil,
        description: String? = nil,
        iconURL: String? = nil,
        category: String? = nil,
        ownerID: UUID,
        latestReleasedVersion: VersionDTO? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.summary = summary
        self.description = description
        self.iconURL = iconURL
        self.category = category
        self.ownerID = ownerID
        self.latestReleasedVersion = latestReleasedVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct VersionDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var appID: UUID
    /// 사람이 보는 버전 문자열. 예: `1.4.2`
    public var shortVersion: String
    /// 단조 증가하는 빌드 번호. 같은 앱 안에서 유일해야 한다.
    public var buildNumber: Int
    public var releaseNotes: String?
    /// 실행에 필요한 최소 macOS 버전. 예: `14.0`
    public var minimumOSVersion: String?
    public var state: VersionState
    public var fileSize: Int64?
    public var sha256: String?
    public var createdAt: Date
    public var releasedAt: Date?

    public init(
        id: UUID,
        appID: UUID,
        shortVersion: String,
        buildNumber: Int,
        releaseNotes: String? = nil,
        minimumOSVersion: String? = nil,
        state: VersionState,
        fileSize: Int64? = nil,
        sha256: String? = nil,
        createdAt: Date,
        releasedAt: Date? = nil
    ) {
        self.id = id
        self.appID = appID
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.releaseNotes = releaseNotes
        self.minimumOSVersion = minimumOSVersion
        self.state = state
        self.fileSize = fileSize
        self.sha256 = sha256
        self.createdAt = createdAt
        self.releasedAt = releasedAt
    }
}

// MARK: - 요청 페이로드

public struct CreateAppRequest: Codable, Sendable {
    public var bundleID: String
    public var name: String
    public var summary: String?
    public var description: String?
    public var category: String?

    public init(
        bundleID: String,
        name: String,
        summary: String? = nil,
        description: String? = nil,
        category: String? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.summary = summary
        self.description = description
        self.category = category
    }
}

/// 이미 서명·공증까지 마친 완성본을 올리는지 여부에 따라 파이프라인이 갈린다.
public enum UploadKind: String, Codable, Sendable {
    /// 워커가 서명·공증을 대행한다.
    case unsigned
    /// 개발자가 로컬에서 서명·공증을 마쳤다. 서명 단계를 건너뛴다.
    case signed
}

public struct CreateVersionRequest: Codable, Sendable {
    public var shortVersion: String
    public var buildNumber: Int
    public var releaseNotes: String?
    public var minimumOSVersion: String?
    public var uploadKind: UploadKind

    public init(
        shortVersion: String,
        buildNumber: Int,
        releaseNotes: String? = nil,
        minimumOSVersion: String? = nil,
        uploadKind: UploadKind = .unsigned
    ) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.releaseNotes = releaseNotes
        self.minimumOSVersion = minimumOSVersion
        self.uploadKind = uploadKind
    }
}

/// 버전 생성 응답. 클라이언트는 이 URL로 바이너리를 직접 올린다.
public struct UploadTicket: Codable, Sendable {
    public var version: VersionDTO
    public var uploadURL: String
    public var expiresAt: Date

    public init(version: VersionDTO, uploadURL: String, expiresAt: Date) {
        self.version = version
        self.uploadURL = uploadURL
        self.expiresAt = expiresAt
    }
}

/// 다운로드 응답. 서버가 이력을 남긴 뒤 만료 있는 URL을 내준다.
public struct DownloadTicket: Codable, Sendable {
    public var downloadURL: String
    public var expiresAt: Date
    public var sha256: String?
    public var fileSize: Int64?

    public init(downloadURL: String, expiresAt: Date, sha256: String? = nil, fileSize: Int64? = nil) {
        self.downloadURL = downloadURL
        self.expiresAt = expiresAt
        self.sha256 = sha256
        self.fileSize = fileSize
    }
}
