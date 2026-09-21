import Foundation

/// 서버가 워커에게 넘기는 서명 작업 지시서.
///
/// 워커는 이 안의 URL만으로 일을 끝낼 수 있어야 한다.
/// 서명 identity와 공증 자격증명은 워커 로컬 설정에서 오며 여기 담기지 않는다.
public struct SigningJobDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var versionID: UUID
    public var appBundleID: String
    /// `appBundleID` 가 아직 확정되지 않은 임시값이다.
    ///
    /// dmg 로 올리면 브라우저가 번들을 열 수 없어 등록 시점에 번들 ID 를 알 수 없다
    /// (ADR-0034). 그때 서버가 임시값을 넣어 보내고, 워커는 등록값과 **대조하는 대신**
    /// 번들에서 읽은 값이 조직 정책에 맞는지 본다. 맞으면 그 값을 보고하고 서버가
    /// 확정한다.
    ///
    /// 옵셔널이라 이 필드를 모르는 예전 워커는 늘 대조하던 대로 동작한다. 그 워커는
    /// 임시값과 실제 값이 달라 실패시키는데, **그것이 안전한 쪽이다.**
    public var appBundleIDPending: Bool?
    /// 조직이 요구하는 번들 ID 접두어. 없으면 정책이 없다.
    public var requiredBundleIDPrefix: String?
    /// 접두어에 맞지 않을 때 막을지, 로그만 남길지.
    public var enforceBundleIDPrefix: Bool?
    /// 미서명 아티팩트를 받아올 만료 있는 URL.
    public var artifactDownloadURL: String
    /// 서명·공증을 마친 결과물을 올릴 만료 있는 URL.
    public var resultUploadURL: String
    /// dmg 로도 감싸서 여기 올리라는 뜻 (ADR-0050). 없으면 만들지 않는다.
    ///
    /// **서버가 정한다.** 워커는 이 잡이 무엇인지 모르고, 알 필요도 없다. 스토어 앱만
    /// dmg 가 필요한데 그것을 아는 것은 서버뿐이다 (`StoreAppSettings`).
    ///
    /// 옵셔널이라 이 필드를 모르는 예전 워커는 지금까지처럼 zip 만 만든다. 그 결과는
    /// 모자랄 뿐 틀리지 않는다.
    public var diskImageUploadURL: String?
    /// 업로더가 함께 올린 entitlements plist 의 XML 원문. 안 올렸으면 nil (ADR-0020).
    ///
    /// 옵셔널이라 합성 디코더가 `decodeIfPresent` 로 읽는다. 이 필드를 모르는 예전
    /// 서버가 보낸 지시서도 그대로 해석된다.
    public var entitlements: String?
    public var expiresAt: Date

    public init(
        id: UUID,
        versionID: UUID,
        appBundleID: String,
        appBundleIDPending: Bool? = nil,
        requiredBundleIDPrefix: String? = nil,
        enforceBundleIDPrefix: Bool? = nil,
        artifactDownloadURL: String,
        resultUploadURL: String,
        diskImageUploadURL: String? = nil,
        entitlements: String? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.versionID = versionID
        self.appBundleID = appBundleID
        self.appBundleIDPending = appBundleIDPending
        self.requiredBundleIDPrefix = requiredBundleIDPrefix
        self.enforceBundleIDPrefix = enforceBundleIDPrefix
        self.artifactDownloadURL = artifactDownloadURL
        self.resultUploadURL = resultUploadURL
        self.diskImageUploadURL = diskImageUploadURL
        self.entitlements = entitlements
        self.expiresAt = expiresAt
    }
}

/// 워커가 잡 진행 상황을 서버에 알릴 때 쓰는 페이로드.
public struct SigningJobUpdate: Codable, Sendable {
    public var state: SigningJobState
    /// 진행 중인 단계. UI에 그대로 노출한다.
    public var phase: SigningPhase?
    /// 사람이 읽는 로그. 실패 원인 파악에 쓴다.
    ///
    /// 서버는 이것을 덮어쓰지 않고 잡 로그 끝에 붙인다. 실패 직전 단계의 로그가
    /// 원인 파악에 가장 필요한데, 덮어쓰면 그것이 사라진다 (ADR-0023).
    public var log: String?
    public var failureReason: String?
    /// 실패의 갈래. 서버가 재시도 여부를 이것으로 판단한다 (ADR-0023).
    ///
    /// 옵셔널이라 합성 디코더가 `decodeIfPresent` 로 읽는다. 이 필드를 모르는 예전
    /// 워커가 보낸 보고도 그대로 받아들인다. 그때는 nil 이고, 서버는 "워커가 실패를
    /// 보고했지만 갈래는 모른다"로 다룬다.
    public var failureCode: SigningFailureCode?
    /// 결과물 검증용. 서버가 업로드된 파일과 대조한다.
    public var resultSHA256: String?
    public var resultSize: Int64?
    /// Sparkle 이 요구하는 EdDSA 서명. 워커에 키가 없으면 비어 있다 (ADR-0017).
    public var resultEdSignature: String?
    /// 번들이 스스로 밝히는 값. 워커가 서명 직전에 `Info.plist` 에서 읽는다.
    ///
    /// **이것이 진실이다.** 브라우저는 dmg 를 열 수 없어서 올린 사람이 손으로 적은
    /// 값을 쓰는데(ADR-0033), 그 값과 다르면 서버가 이쪽으로 고친다. 실제로 배포되는
    /// 바이너리가 무엇인지는 이 파일만 답할 수 있다.
    ///
    /// 옵셔널이라 합성 디코더가 `decodeIfPresent` 로 읽는다. 이 필드를 모르는 예전
    /// 워커가 보낸 보고도 그대로 받아들인다.
    public var bundleMetadata: BundleMetadata?
    /// dmg 를 만들어 올렸으면 그 검증값 (ADR-0050). 안 만들었으면 nil 이다.
    ///
    /// zip 과 같은 이유로 서버가 스토리지에서 한 번 더 확인한다. 워커가 "올렸다" 고
    /// 말하는 것만 믿으면 빈 dmg 가 붙은 버전이 출시된다.
    public var diskImageSHA256: String?
    public var diskImageSize: Int64?

    public init(
        state: SigningJobState,
        phase: SigningPhase? = nil,
        log: String? = nil,
        failureReason: String? = nil,
        failureCode: SigningFailureCode? = nil,
        resultSHA256: String? = nil,
        resultSize: Int64? = nil,
        resultEdSignature: String? = nil,
        bundleMetadata: BundleMetadata? = nil,
        diskImageSHA256: String? = nil,
        diskImageSize: Int64? = nil
    ) {
        self.state = state
        self.phase = phase
        self.log = log
        self.failureReason = failureReason
        self.failureCode = failureCode
        self.resultSHA256 = resultSHA256
        self.resultSize = resultSize
        self.resultEdSignature = resultEdSignature
        self.bundleMetadata = bundleMetadata
        self.diskImageSHA256 = diskImageSHA256
        self.diskImageSize = diskImageSize
    }
}

/// 번들의 `Info.plist` 에서 읽은 값.
///
/// 번들 ID 는 여기 없다. 그것은 서명 전에 등록된 값과 대조해서 다르면 실패시키므로
/// (ADR-0029), 보고가 도착했다는 것 자체가 이미 같다는 뜻이다.
public struct BundleMetadata: Codable, Sendable, Equatable {
    /// `CFBundleShortVersionString`.
    public var shortVersion: String?
    /// `CFBundleVersion`. 문자열이다. `1.2.3` 처럼 적는 앱이 흔해서 정수로 두지 않는다.
    public var buildVersion: String?
    /// `LSMinimumSystemVersion`.
    public var minimumOSVersion: String?
    /// `CFBundleIdentifier`. **등록값이 임시일 때만 담는다.**
    ///
    /// 확정된 앱에서는 보내지 않는다. 서명 전에 이미 대조해서 같다는 것을 알고
    /// (ADR-0029), 같은 값을 또 보내면 받는 쪽이 "다르면 어느 쪽을 믿나" 를 고민해야
    /// 한다. 임시일 때만 서버가 이 값으로 확정한다 (ADR-0034).
    public var bundleIdentifier: String?

    public init(
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        minimumOSVersion: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
        self.bundleIdentifier = bundleIdentifier
    }

    /// 하나도 못 읽었으면 보내지 않는다.
    public var isEmpty: Bool {
        shortVersion == nil && buildVersion == nil && minimumOSVersion == nil
            && bundleIdentifier == nil
    }
}

/// 워커 파이프라인의 세부 단계.
public enum SigningPhase: String, Codable, Sendable, CaseIterable {
    case downloading
    /// restricted entitlement를 쓰는데 프로필이 없는 번들을 걸러낸다.
    case validating
    case codesigning
    case notarizing
    case stapling
    /// dmg 로 감싸는 중 (ADR-0050). 그 잡에만 지나간다.
    case packaging
    case uploading

    public var displayName: String {
        switch self {
        case .downloading: return "내려받는 중"
        case .validating: return "번들 검사 중"
        case .codesigning: return "서명 중"
        case .notarizing: return "공증 대기 중"
        case .stapling: return "공증 티켓 첨부 중"
        case .packaging: return "dmg 만드는 중"
        case .uploading: return "올리는 중"
        }
    }
}

/// 워커가 서버에 자기 상태를 알리는 하트비트.
public struct WorkerHeartbeat: Codable, Sendable {
    public var workerName: String
    /// 워커가 도는 머신의 macOS 버전. 공증 도구 호환성 확인에 쓴다.
    public var osVersion: String
    /// 지금 처리 중인 잡. 놀고 있으면 nil.
    public var currentJobID: UUID?
    /// 이 워커가 어느 버전인지 (ADR-0042).
    ///
    /// 옵셔널인 이유는 이 필드를 모르는 옛 워커가 계속 붙어 있기 때문이다. 그런
    /// 워커는 nil 로 남고, 화면은 "모름" 으로 그린다. 모름이 곧 낡았다는 뜻이라
    /// 그 자체로 쓸모가 있다.
    public var workerVersion: String?
    /// 이 워커가 Sparkle 서명에 쓰는 **공개키** (ADR-0057).
    ///
    /// **개인키는 보내지 않는다.** 공개키는 개인키에서 계산한 값이고, 앱의
    /// `SUPublicEDKey` 에 그대로 들어가는 공개 정보다. 서버가 이것을 알아야 앱을
    /// 만드는 사람에게 "이 값을 넣으세요" 라고 화면에서 말해줄 수 있다.
    ///
    /// 키를 안 넣은 워커는 nil 을 보낸다. 그 상태가 곧 "이 워커가 서명한 것은
    /// Sparkle 이 거부한다" 는 뜻이라, nil 자체가 알려야 할 정보다.
    public var sparklePublicKey: String?

    public init(
        workerName: String,
        osVersion: String,
        currentJobID: UUID? = nil,
        workerVersion: String? = WorkerVersion.current,
        sparklePublicKey: String? = nil
    ) {
        self.workerName = workerName
        self.osVersion = osVersion
        self.workerVersion = workerVersion
        self.sparklePublicKey = sparklePublicKey
        self.currentJobID = currentJobID
        self.workerVersion = workerVersion
    }
}

/// 지금 배포 중인 워커 번들 (ADR-0042).
///
/// 워커가 자기 버전과 견줘 낮으면 `downloadURL` 로 받아 자기를 갈아끼운다.
public struct WorkerReleaseDTO: Codable, Sendable, Equatable {
    public var version: String
    /// 만료 있는 내려받기 주소. 다른 아티팩트와 같은 방식이다 (ADR-0009).
    public var downloadURL: String
    public var fileSize: Int64
    /// 받은 파일이 올린 그 파일인지 대조한다.
    public var sha256: String

    public init(version: String, downloadURL: String, fileSize: Int64, sha256: String) {
        self.version = version
        self.downloadURL = downloadURL
        self.fileSize = fileSize
        self.sha256 = sha256
    }
}

/// 올려둔 워커 릴리스 한 줄.
public struct WorkerReleaseSummaryDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var version: String
    public var fileSize: Int64
    public var sha256: String
    public var isCurrent: Bool
    public var createdAt: Date

    public init(
        id: UUID,
        version: String,
        fileSize: Int64,
        sha256: String,
        isCurrent: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.version = version
        self.fileSize = fileSize
        self.sha256 = sha256
        self.isCurrent = isCurrent
        self.createdAt = createdAt
    }
}

// MARK: - 워커 등록

/// 등록된 워커 한 대. 토큰은 여기 없다.
public struct WorkerDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// 마지막으로 서버에 말을 건 시각. 하트비트와 잡 폴링 양쪽이 갱신한다.
    public var lastSeenAt: Date?
    public var osVersion: String?
    /// 이 워커가 마지막으로 알린 자기 버전. 이 필드를 모르는 옛 워커는 nil (ADR-0042).
    public var workerVersion: String?
    public var currentJobID: UUID?
    /// 폐기된 워커는 토큰이 더 이상 통하지 않는다. 기록은 남긴다.
    public var revokedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID,
        name: String,
        lastSeenAt: Date? = nil,
        osVersion: String? = nil,
        workerVersion: String? = nil,
        currentJobID: UUID? = nil,
        revokedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.lastSeenAt = lastSeenAt
        self.osVersion = osVersion
        self.currentJobID = currentJobID
        self.revokedAt = revokedAt
        self.createdAt = createdAt
    }
}

public struct CreateWorkerRequest: Codable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// 워커를 등록한 직후에만 한 번 내려주는 응답.
///
/// 서버는 토큰의 해시만 저장하므로 이 순간을 놓치면 다시 볼 수 없다.
/// 잃어버리면 새로 발급받아야 한다.
public struct CreatedWorker: Codable, Sendable {
    public var worker: WorkerDTO
    public var token: String

    public init(worker: WorkerDTO, token: String) {
        self.worker = worker
        self.token = token
    }
}
