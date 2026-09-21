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
    ///
    /// `bundleIDPending` 이 참이면 이 값은 서버가 자리를 채우려고 넣은 임시값이다.
    /// 그 앱은 아직 출시할 수 없다 (ADR-0034).
    public var bundleID: String
    /// 번들 ID 가 아직 확정되지 않았다. dmg 로 올린 직후가 그렇다.
    ///
    /// 옵셔널이라 이 필드를 모르는 예전 클라이언트도 그대로 동작한다.
    public var bundleIDPending: Bool?
    public var name: String
    public var summary: String?
    public var description: String?
    public var iconURL: String?
    public var category: String?
    public var ownerID: UUID
    /// 현재 조직에 출시된 최신 버전. 아직 출시본이 없으면 nil.
    public var latestReleasedVersion: VersionDTO?
    /// 별점 요약. 목록에서도 보여주므로 앱과 함께 내려준다.
    public var rating: RatingSummary?
    /// 이 앱이 스토어 앱 자신인가.
    ///
    /// **스토어 앱은 자기를 목록에 세우지 않는다.** 자기를 갈아끼우는 것은 다른 앱을
    /// 받는 것과 달라서(앱이 종료되고 다시 뜬다) 목록의 한 줄로 두면 안 되고, 그 일은
    /// 위쪽 배너가 맡는다.
    ///
    /// 그것을 번들 ID 로 견주면 어긋날 때가 있다. 관리자가 번들 ID 를 바꾸면 이미
    /// 깔린 스토어 앱들은 자기를 못 알아보고 새 스토어 앱을 목록에 세운다. 로컬에서
    /// 만든 빌드를 다른 서버에 붙일 때도 그렇다. 어느 앱이 스토어 앱인지는 서버가
    /// 알고 있으므로(ADR-0046) 서버가 말해준다.
    ///
    /// 옵셔널이라 이 필드를 모르는 예전 서버에도 그대로 붙는다. 그때는 클라이언트가
    /// 번들 ID 로 견준다.
    public var isStoreApp: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        bundleID: String,
        bundleIDPending: Bool? = nil,
        name: String,
        summary: String? = nil,
        description: String? = nil,
        iconURL: String? = nil,
        category: String? = nil,
        ownerID: UUID,
        latestReleasedVersion: VersionDTO? = nil,
        rating: RatingSummary? = nil,
        isStoreApp: Bool? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.bundleID = bundleID
        self.bundleIDPending = bundleIDPending
        self.name = name
        self.summary = summary
        self.description = description
        self.iconURL = iconURL
        self.category = category
        self.ownerID = ownerID
        self.latestReleasedVersion = latestReleasedVersion
        self.rating = rating
        self.isStoreApp = isStoreApp
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
    /// 서명이 실패한 이유. 실패한 버전에만 있다.
    ///
    /// 올린 뒤 확인 화면이 이것을 보여준다. 그 화면은 워커가 값을 채울 때까지
    /// 기다리는 자리라, 실패했을 때 왜 실패했는지도 거기서 알려줘야 한다.
    public var failureReason: String?

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
        releasedAt: Date? = nil,
        failureReason: String? = nil
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
        self.failureReason = failureReason
    }
}

// MARK: - 요청 페이로드

public struct CreateAppRequest: Codable, Sendable {
    /// 등록할 번들 ID. **비워 보낼 수 있다.**
    ///
    /// dmg 로 올릴 때가 그렇다. 브라우저가 디스크 이미지를 열 수 없어서 올리기 전에는
    /// 이 값을 알 수 없다. 비워 보내면 서버가 임시 ID 를 만들어두고, 워커가 번들에서
    /// 읽은 값으로 확정한다 (ADR-0034).
    ///
    /// 옵셔널이라 합성 디코더가 `decodeIfPresent` 로 읽는다. 이 값을 늘 보내던 예전
    /// 클라이언트는 그대로 동작한다.
    public var bundleID: String?
    public var name: String
    public var summary: String?
    public var description: String?
    public var category: String?

    public init(
        bundleID: String? = nil,
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

/// **더 이상 쓰이지 않는다.** 서버가 받기는 하지만 무시한다 (ADR-0035).
///
/// 예전에는 올린 사람이 "이미 서명했다" 를 고르면 서버가 워커를 건너뛰었다. 그 말을
/// 검사하는 자리가 없어서, 서명 안 된 앱이 그대로 배포될 수 있었다. 지금은 워커가
/// 번들을 열어보고 판정한다.
///
/// 타입을 지우지 않는 이유는 이 값을 보내던 옛 스크립트를 400 으로 죽이지 않기
/// 위해서다. 그들이 다 사라지면 지운다.
public enum UploadKind: String, Codable, Sendable, CaseIterable {
    case unsigned
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
    /// 서명·공증까지 마친 `.dmg` (ADR-0050).
    ///
    /// **스토어 앱에만 붙는다.** 다른 앱은 스토어 앱이 받아서 `/Applications` 에
    /// 직접 넣으므로 사람이 옮길 일이 없다. 스토어 앱 자신만 사람이 손으로 옮기고,
    /// 그때 dmg 안의 Applications 별칭이 그 일을 한 번의 드래그로 만든다.
    case diskImage = "dmg"

    /// 파일 확장자. 오브젝트 키와 받는 파일 이름이 이것으로 갈린다.
    public var fileExtension: String {
        switch self {
        case .unsigned, .signed: return "zip"
        case .diskImage: return "dmg"
        }
    }
}

public struct CreateVersionRequest: Codable, Sendable {
    public var shortVersion: String
    public var buildNumber: Int
    public var releaseNotes: String?
    public var minimumOSVersion: String?
    /// **더 이상 쓰이지 않는다.** 워커가 번들을 열어보고 판정한다 (ADR-0035).
    ///
    /// 서버가 이 값을 무시한다. 옵셔널이라 안 보내도 되고, 예전 CLI 가 보내도
    /// 요청이 깨지지 않는다. 합성 디코더는 프로퍼티 기본값을 쓰지 않으므로
    /// 옵셔널이어야 빠뜨린 요청이 통한다.
    public var uploadKind: UploadKind?
    /// 서명할 때 붙일 entitlements plist 의 XML 원문. 안 보내도 된다 (ADR-0020).
    ///
    /// 미서명 업로드에는 읽어낼 기존 서명이 없어서 워커가 이것을 짐작할 수 없다.
    /// 파일이 1KB 도 되지 않아 presigned URL 세 단계를 새로 만들지 않고 본문에 싣는다
    /// (ADR-0016 의 선례).
    public var entitlements: String?

    public init(
        shortVersion: String,
        buildNumber: Int,
        releaseNotes: String? = nil,
        minimumOSVersion: String? = nil,
        uploadKind: UploadKind? = nil,
        entitlements: String? = nil
    ) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.releaseNotes = releaseNotes
        self.minimumOSVersion = minimumOSVersion
        self.uploadKind = uploadKind
        self.entitlements = entitlements
    }

    /// `uploadKind` 를 안 보내면 미서명으로 본다. 대부분이 그 경우다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shortVersion = try container.decode(String.self, forKey: .shortVersion)
        self.buildNumber = try container.decode(Int.self, forKey: .buildNumber)
        self.releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
        self.minimumOSVersion = try container.decodeIfPresent(
            String.self, forKey: .minimumOSVersion
        )
        self.uploadKind = try container.decodeIfPresent(
            UploadKind.self, forKey: .uploadKind
        ) ?? .unsigned
        self.entitlements = try container.decodeIfPresent(String.self, forKey: .entitlements)
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

/// CI 파이프라인이 쓰는 앱별 배포 토큰.
///
/// 토큰 값은 여기 없다. 발급 직후 한 번만 내려간다 (ADR-0015).
public struct DeployTokenDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var appID: UUID
    public var name: String
    /// 마지막으로 이 토큰이 쓰인 시각. 안 쓰는 토큰을 찾아 지울 때 본다.
    public var lastUsedAt: Date?
    public var revokedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID,
        appID: UUID,
        name: String,
        lastUsedAt: Date? = nil,
        revokedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.appID = appID
        self.name = name
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
        self.createdAt = createdAt
    }
}

public struct CreateDeployTokenRequest: Codable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// 배포 토큰을 발급한 직후에만 한 번 내려주는 응답.
public struct CreatedDeployToken: Codable, Sendable {
    public var token: DeployTokenDTO
    public var value: String

    public init(token: DeployTokenDTO, value: String) {
        self.token = token
        self.value = value
    }
}

// MARK: - 피드백

/// 사용자가 버전 하나에 남긴 별점과 의견.
///
/// 별점과 글은 둘 다 선택이지만 하나는 있어야 한다. 별점만 주고 싶은 사람과
/// 버그만 알리고 싶은 사람이 둘 다 있다.
public struct FeedbackDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var appID: UUID
    public var versionID: UUID
    /// 어느 버전에 남긴 것인지 화면에 보여주려고 함께 내려준다.
    public var versionName: String
    /// 1~5. 글만 남겼으면 nil.
    public var rating: Int?
    public var body: String?
    /// 첨부한 스크린샷을 받을 수 있는 만료 있는 URL. 없으면 nil.
    public var screenshotURL: String?
    /// 남긴 사람. 익명으로 남겼으면 nil.
    public var author: UserDTO?
    public var isAnonymous: Bool
    /// 지금 보는 사람이 고치거나 지울 수 있는지.
    public var isMine: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        appID: UUID,
        versionID: UUID,
        versionName: String,
        rating: Int? = nil,
        body: String? = nil,
        screenshotURL: String? = nil,
        author: UserDTO? = nil,
        isAnonymous: Bool = false,
        isMine: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.appID = appID
        self.versionID = versionID
        self.versionName = versionName
        self.rating = rating
        self.body = body
        self.screenshotURL = screenshotURL
        self.author = author
        self.isAnonymous = isAnonymous
        self.isMine = isMine
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 앱 하나의 별점 요약.
public struct RatingSummary: Codable, Sendable, Equatable {
    /// 별점을 남긴 사람 수. 글만 남긴 것은 세지 않는다.
    public var count: Int
    /// 평균. 아무도 안 남겼으면 nil.
    public var average: Double?

    public init(count: Int, average: Double? = nil) {
        self.count = count
        self.average = average
    }

    /// 화면에 쓰는 한 자리 반올림. 3.25 는 "3.3".
    ///
    /// `%.1f` 에 그대로 맡기지 않는다. 그쪽은 짝수 반올림이라 3.25 가 "3.2" 가 되고,
    /// 사람이 기대하는 사사오입과 어긋난다. 별점 0.1 이 큰 값은 아니지만 화면에 뜨는
    /// 숫자가 손으로 계산한 것과 다르면 다른 것도 못 믿게 된다.
    public var displayAverage: String? {
        guard let average else { return nil }
        return String(format: "%.1f", (average * 10).rounded() / 10)
    }
}

public struct SubmitFeedbackRequest: Codable, Sendable {
    public var rating: Int?
    public var body: String?
    /// 이름을 감출지. 서버는 누가 남겼는지 계속 알고 있다.
    public var isAnonymous: Bool

    public init(rating: Int? = nil, body: String? = nil, isAnonymous: Bool = false) {
        self.rating = rating
        self.body = body
        self.isAnonymous = isAnonymous
    }

    /// 안 보낸 항목은 기본값으로 본다.
    ///
    /// 기본 합성 디코더는 `Bool` 을 필수로 본다. 그러면 `{"rating": 5}` 처럼 당연해
    /// 보이는 요청이 400 으로 떨어진다. 초기값이 있는 항목은 없어도 되게 한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
        self.isAnonymous = try container.decodeIfPresent(Bool.self, forKey: .isAnonymous) ?? false
    }
}

/// Sparkle 피드용 앱별 토큰.
///
/// 값은 여기 없다. 발급 직후 한 번만 내려간다 (ADR-0017).
public struct FeedTokenDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var appID: UUID
    public var name: String
    public var lastUsedAt: Date?
    public var revokedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID,
        appID: UUID,
        name: String,
        lastUsedAt: Date? = nil,
        revokedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.appID = appID
        self.name = name
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
        self.createdAt = createdAt
    }
}

public struct CreateFeedTokenRequest: Codable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// 피드 토큰을 발급한 직후에만 한 번 내려주는 응답.
public struct CreatedFeedToken: Codable, Sendable {
    public var token: FeedTokenDTO
    public var value: String
    /// 앱의 `SUFeedURL` 에 그대로 넣을 주소. 토큰이 들어 있다.
    public var feedURL: String

    public init(token: FeedTokenDTO, value: String, feedURL: String) {
        self.token = token
        self.value = value
        self.feedURL = feedURL
    }
}

// MARK: - 알림

/// 알림을 보낼 곳.
public struct NotificationTargetDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// 앱에 붙은 대상이면 그 앱. 전역 대상(워커 알림 등)이면 nil.
    public var appID: UUID?
    public var kind: NotificationChannelKind
    /// 사람이 알아볼 이름.
    public var name: String
    /// 어디로 가는지. **숨길 것이 아닐 때만 채운다.**
    ///
    /// 웹훅 URL 은 그 채널에 글을 쓸 수 있는 자격증명이라 등록할 때만 받고 다시
    /// 내려주지 않는다. 메일 주소는 자격증명이 아니라 그냥 주소다. 가려놓으면 지운
    /// 대상을 다시 만들 때 무엇이 있었는지 알 길이 없고, 이름만 보고 짐작해야 한다.
    public var endpoint: String?
    public var createdAt: Date

    public init(
        id: UUID,
        appID: UUID? = nil,
        kind: NotificationChannelKind,
        name: String,
        endpoint: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.appID = appID
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
        self.createdAt = createdAt
    }
}

/// 알림을 어디로 보낼지 (ADR-0059).
///
/// **앱 알림과 운영 알림이 같은 것을 고른다.** 받는 사람이 누구인지만 다르다. 앱이면
/// 올릴 수 있는 사람들이고, 운영이면 스토어 관리자들이다. 한 화면을 이해하면 나머지도
/// 알도록 모양을 맞춘다.
///
/// **둘 중 하나만 고른다.** 함께 보내는 선택지를 두지 않는 이유는, 그것을 고른
/// 조직에서 같은 알림이 채널과 개인에게 두 번 오기 때문이다. 두 번 오는 알림은
/// 한 번 오는 알림보다 빨리 무시당한다.
public enum AlertDelivery: String, Codable, Sendable, CaseIterable {
    /// 등록해 둔 Slack 채널로. 여러 명이 보고 이력이 남는다.
    case channel
    /// 그 알림을 받아야 할 사람들에게 한 명씩. 등록할 것이 없어 설정을 잊어도 닿는다.
    ///
    /// 어떤 수단으로 가는지는 사람마다 다르다. 각자 내 알림에서 정한 것을 따른다
    /// (`User.notifyVia`).
    case people

    public var displayName: String {
        switch self {
        case .channel: return "Slack 채널"
        case .people: return "개별 전송"
        }
    }
}

/// 알림을 보내는 방식.
///
/// 채널을 타입으로 둔 덕에 메일을 붙일 때 부르는 쪽이 그대로였다. 보내는 구현만
/// 하나 늘고, 대상 행은 `kind` 로 갈린다.
public enum NotificationChannelKind: String, Codable, Sendable, CaseIterable {
    /// Slack Incoming Webhook. 정해진 채널 하나에 쓴다.
    case slack
    /// Slack DM. 봇 토큰으로 사람에게 직접 보낸다.
    ///
    /// **관리자가 고르는 값이 아니다.** 알림 대상 화면에는 나오지 않는다. 앱에 붙이는
    /// 대상은 채널이고, 이쪽은 "그 버전을 올린 사람" 처럼 서버가 받는 사람을 아는
    /// 경우에만 쓴다 (`Notifier.notify(person:)`).
    case slackDirectMessage = "slack_dm"
    /// 메일. 사람에게도 보내고 앱 대상으로 등록할 수도 있다.
    case email

    /// 알림 대상으로 등록할 수 있는 것들.
    ///
    /// **웹훅뿐이다** (ADR-0059). 대상으로 등록하는 것은 채널이고, 사람에게 보내는
    /// 길은 개별 전송이 맡는다. 그쪽은 받는 사람이 각자 수단을 정하므로 등록할 주소가
    /// 없다.
    ///
    /// 메일 주소를 앱 대상으로 다는 것은 ADR-0058 에서 열었다가 ADR-0059 에서 닫았다.
    /// 이미 등록해 둔 행은 그대로 발송되고, 새로 만들 수만 없다.
    public static var selectable: [NotificationChannelKind] { [.slack] }

    /// 사람 한 명에게 보낼 때 쓸 수 있는 것들.
    ///
    /// 웹훅은 여기 없다. 채널 주소라 그 사람에게만 가지 않는다.
    public static var personal: [NotificationChannelKind] { [.slackDirectMessage, .email] }

    public var displayName: String {
        switch self {
        case .slack: return "Slack"
        case .slackDirectMessage: return "Slack DM"
        case .email: return "메일"
        }
    }
}

public struct CreateNotificationTargetRequest: Codable, Sendable {
    public var kind: NotificationChannelKind
    public var name: String
    public var endpoint: String

    public init(kind: NotificationChannelKind = .slack, name: String, endpoint: String) {
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
    }

    /// 채널을 안 밝히면 Slack 으로 본다. 메일이 생기기 전에 만들어진 클라이언트가
    /// 이 칸 없이 보내고, 그때는 웹훅뿐이었다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decodeIfPresent(
            NotificationChannelKind.self, forKey: .kind
        ) ?? .slack
        self.name = try container.decode(String.self, forKey: .name)
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
    }
}

// MARK: - App Store Connect

/// 개발자 포털의 인증서 하나.
///
/// 개인키는 여기 없다. 서버는 애초에 모른다(ADR-0002). "언제 만료되는가"만 본다.
public struct ASCCertificate: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// `DEVELOPER_ID_APPLICATION` 같은 Apple 쪽 분류.
    public var type: String
    public var serialNumber: String?
    public var expiresAt: Date?

    public init(
        id: String,
        name: String,
        type: String,
        serialNumber: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.serialNumber = serialNumber
        self.expiresAt = expiresAt
    }

    /// 서명에 쓰는 인증서인지.
    ///
    /// 만료되면 워커가 서명을 못 한다. 다른 종류는 참고 정보다.
    public var isDeveloperID: Bool {
        type.uppercased().contains("DEVELOPER_ID")
    }

    /// 만료까지 남은 날. 이미 지났으면 음수.
    public func daysUntilExpiry(from now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        return Calendar(identifier: .gregorian).dateComponents(
            [.day], from: now, to: expiresAt
        ).day
    }
}

/// 개발자 포털에 등록된 App ID 하나.
public struct ASCBundleID: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// `com.example.tool` 또는 와일드카드 `com.example.*`
    public var identifier: String
    public var name: String
    public var platform: String

    public init(id: String, identifier: String, name: String, platform: String) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.platform = platform
    }

    public var isWildcard: Bool {
        identifier.hasSuffix("*")
    }

    /// 이 와일드카드가 저 번들 ID 를 덮는지.
    ///
    /// `com.example.*` 는 `com.example.tool` 을 덮지만 `com.other.tool` 은 못 덮는다.
    public func covers(_ bundleID: String) -> Bool {
        guard isWildcard else { return identifier == bundleID }
        let prefix = String(identifier.dropLast())
        return bundleID.hasPrefix(prefix)
    }
}

public struct RegisterBundleIDRequest: Codable, Sendable {
    public var identifier: String
    public var name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
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
