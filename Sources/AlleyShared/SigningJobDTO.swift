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
    public var expiresAt: Date

    public init(
        id: UUID,
        versionID: UUID,
        appBundleID: String,
        artifactDownloadURL: String,
        resultUploadURL: String,
        expiresAt: Date
    ) {
        self.id = id
        self.versionID = versionID
        self.appBundleID = appBundleID
        self.artifactDownloadURL = artifactDownloadURL
        self.resultUploadURL = resultUploadURL
        self.expiresAt = expiresAt
    }
}

/// 워커가 잡 진행 상황을 서버에 알릴 때 쓰는 페이로드.
public struct SigningJobUpdate: Codable, Sendable {
    public var state: SigningJobState
    /// 진행 중인 단계. UI에 그대로 노출한다.
    public var phase: SigningPhase?
    /// 사람이 읽는 로그. 실패 원인 파악에 쓴다.
    public var log: String?
    public var failureReason: String?
    /// 결과물 검증용. 서버가 업로드된 파일과 대조한다.
    public var resultSHA256: String?
    public var resultSize: Int64?
    /// Sparkle 이 요구하는 EdDSA 서명. 워커에 키가 없으면 비어 있다 (ADR-0017).
    public var resultEdSignature: String?

    public init(
        state: SigningJobState,
        phase: SigningPhase? = nil,
        log: String? = nil,
        failureReason: String? = nil,
        resultSHA256: String? = nil,
        resultSize: Int64? = nil,
        resultEdSignature: String? = nil
    ) {
        self.state = state
        self.phase = phase
        self.log = log
        self.failureReason = failureReason
        self.resultSHA256 = resultSHA256
        self.resultSize = resultSize
        self.resultEdSignature = resultEdSignature
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
