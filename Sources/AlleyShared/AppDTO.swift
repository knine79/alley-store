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

    /// 화면에 그대로 쓰는 이름.
    ///
    /// `VersionState.displayName` 과 같은 이유로 여기 둔다. 웹 콘솔과 스토어 앱이
    /// 각자 번역하면 같은 역할이 화면마다 다른 이름으로 보인다.
    public var displayName: String {
        switch self {
        case .user: return "사용자"
        case .developer: return "개발자"
        case .admin: return "관리자"
        }
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
    /// 현재 조직에 출시된 최신 버전. 아직 출시본이 없으면 nil.
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
public enum UploadKind: String, Codable, Sendable, CaseIterable {
    /// 워커가 서명·공증을 대행한다.
    case unsigned
    /// 개발자가 로컬에서 서명·공증을 마쳤다. 서명 단계를 건너뛴다.
    case signed
}

/// 스토리지에 올라간 파일 하나의 성격.
///
/// `UploadKind` 와 값이 같지만 뜻이 다르다. `UploadKind` 는 "이 버전을 어떤
/// 파이프라인으로 처리할까"이고, 이 타입은 "이 파일이 서명된 것인가"이다.
/// 미서명으로 올린 버전은 워커가 서명본을 만들어 붙이므로 두 종류를 함께 갖는다.
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case unsigned
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

/// 업로드가 끝났음을 서버에 알리는 요청.
///
/// 서버는 이 통지를 받고서야 스토리지에 파일이 실제로 있는지 확인하고
/// 버전 상태를 넘긴다. 통지 없이 올리기만 하면 버전은 `draft` 로 남는다.
public struct CompleteUploadRequest: Codable, Sendable {
    /// 클라이언트가 계산한 업로드본의 SHA-256(소문자 16진수).
    ///
    /// 전송 중 손상을 잡기 위한 값이다. 올린 사람이 거짓을 적을 수는 있지만
    /// 그건 자기 바이너리에 대한 거짓이고, 받는 쪽의 진짜 방어선은
    /// 설치 직전의 서명·Team ID 검증이다.
    public var sha256: String?

    public init(sha256: String? = nil) {
        self.sha256 = sha256
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

/// 번들 ID 대장의 한 줄.
///
/// 새 앱을 만들기 전에 어떤 ID가 이미 쓰이는지 보라고 내려준다.
/// 중복 등록을 시도해서 거절당하기 전에 스스로 확인할 수 있어야 한다.
public struct BundleIDEntry: Codable, Sendable, Equatable {
    public var bundleID: String
    public var appID: UUID
    public var appName: String
    public var ownerEmail: String

    public init(bundleID: String, appID: UUID, appName: String, ownerEmail: String) {
        self.bundleID = bundleID
        self.appID = appID
        self.appName = appName
        self.ownerEmail = ownerEmail
    }
}

/// 앱에 업로드 권한을 가진 사람.
public struct AppMemberDTO: Codable, Sendable, Equatable {
    public var user: UserDTO
    /// 앱을 만든 사람인지. 오너는 멤버 목록을 고칠 수 있고 스스로 빠질 수 없다.
    public var isOwner: Bool

    public init(user: UserDTO, isOwner: Bool) {
        self.user = user
        self.isOwner = isOwner
    }
}

public struct AddAppMemberRequest: Codable, Sendable {
    /// 추가할 사람의 이메일. 이미 한 번이라도 로그인한 계정이어야 한다.
    public var email: String

    public init(email: String) {
        self.email = email
    }
}

/// 스토어 앱이 일회용 코드를 세션 토큰으로 바꿀 때 보내는 요청.
///
/// 앱은 브라우저가 아니라 쿠키를 받을 수 없다. 그래서 로그인 콜백으로 코드만 받고,
/// 그 코드를 이 요청으로 한 번 교환한다 (ADR-0008).
public struct TokenExchangeRequest: Codable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public struct TokenExchangeResponse: Codable, Sendable {
    public var token: String
    /// 토큰이 유효한 시간(초).
    public var expiresIn: Int
    public var user: UserDTO

    public init(token: String, expiresIn: Int, user: UserDTO) {
        self.token = token
        self.expiresIn = expiresIn
        self.user = user
    }
}

/// 사용자 역할 변경 요청.
public struct UpdateUserRoleRequest: Codable, Sendable {
    public var role: UserRole

    public init(role: UserRole) {
        self.role = role
    }
}

/// 앱 메타데이터 수정 요청.
///
/// 번들 ID는 여기 없다. 이미 설치된 앱의 정체성이라 바꾸면 다른 앱이 된다.
public struct UpdateAppRequest: Codable, Sendable {
    public var name: String?
    public var summary: String?
    public var description: String?
    public var category: String?
    public var iconURL: String?

    public init(
        name: String? = nil,
        summary: String? = nil,
        description: String? = nil,
        category: String? = nil,
        iconURL: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.description = description
        self.category = category
        self.iconURL = iconURL
    }
}
