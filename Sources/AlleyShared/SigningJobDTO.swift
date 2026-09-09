import Foundation

/// 서버가 워커에게 넘기는 서명 작업 지시서.
///
/// 워커는 이 안의 URL만으로 일을 끝낼 수 있어야 한다.
/// 서명 identity와 공증 자격증명은 워커 로컬 설정에서 오며 여기 담기지 않는다.
public struct SigningJobDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var versionID: UUID
    public var appBundleID: String
    /// 미서명 아티팩트를 받아올 만료 있는 URL.
    public var artifactDownloadURL: String
    /// 서명·공증을 마친 결과물을 올릴 만료 있는 URL.
    public var resultUploadURL: String
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
        artifactDownloadURL: String,
        resultUploadURL: String,
        entitlements: String? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.versionID = versionID
        self.appBundleID = appBundleID
        self.artifactDownloadURL = artifactDownloadURL
        self.resultUploadURL = resultUploadURL
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

    public init(
        state: SigningJobState,
        phase: SigningPhase? = nil,
        log: String? = nil,
        failureReason: String? = nil,
        failureCode: SigningFailureCode? = nil,
        resultSHA256: String? = nil,
        resultSize: Int64? = nil,
        resultEdSignature: String? = nil,
        bundleMetadata: BundleMetadata? = nil
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

    public init(
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        minimumOSVersion: String? = nil
    ) {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
    }

    /// 하나도 못 읽었으면 보내지 않는다.
    public var isEmpty: Bool {
        shortVersion == nil && buildVersion == nil && minimumOSVersion == nil
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
    case uploading

    public var displayName: String {
        switch self {
        case .downloading: return "내려받는 중"
        case .validating: return "번들 검사 중"
        case .codesigning: return "서명 중"
        case .notarizing: return "공증 대기 중"
        case .stapling: return "공증 티켓 첨부 중"
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

    public init(workerName: String, osVersion: String, currentJobID: UUID? = nil) {
        self.workerName = workerName
        self.osVersion = osVersion
        self.currentJobID = currentJobID
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
    public var currentJobID: UUID?
    /// 폐기된 워커는 토큰이 더 이상 통하지 않는다. 기록은 남긴다.
    public var revokedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID,
        name: String,
        lastSeenAt: Date? = nil,
        osVersion: String? = nil,
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
