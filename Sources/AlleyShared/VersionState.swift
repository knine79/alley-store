import Foundation

/// 버전 하나가 업로드부터 사내 출시까지 거치는 상태.
///
/// ```
/// draft → uploaded → signing → notarizing → ready → released
///                       └────── failed (재시도 가능) ──────┘
/// ```
///
/// 로컬에서 이미 서명·공증을 마친 완성본을 올리는 경우에는
/// `uploaded`에서 서명 단계를 건너뛰고 바로 `ready`로 간다.
public enum VersionState: String, Codable, Sendable, CaseIterable {
    /// 메타데이터만 만들어졌고 아직 바이너리가 없다.
    case draft
    /// 바이너리 업로드가 끝났다.
    case uploaded
    /// 워커가 코드 서명 중이다.
    case signing
    /// Apple 공증 결과를 기다리는 중이다.
    case notarizing
    /// 서명·공증이 끝나 배포 가능한 아티팩트가 준비됐다.
    case ready
    /// 사내에 공개됐다. 스토어 앱 목록에 노출된다.
    case released
    /// 파이프라인이 실패했다. 로그를 확인하고 재시도할 수 있다.
    case failed

    /// 이 상태에서 넘어갈 수 있는 다음 상태들.
    public var allowedNextStates: Set<VersionState> {
        switch self {
        case .draft:
            return [.uploaded, .failed]
        case .uploaded:
            // 완성본 업로드 경로는 서명을 건너뛰고 바로 ready로 간다.
            return [.signing, .ready, .failed]
        case .signing:
            return [.notarizing, .failed]
        case .notarizing:
            return [.ready, .failed]
        case .ready:
            return [.released, .failed]
        case .released:
            // 출시를 되돌리면 배포 가능하지만 비공개인 ready로 돌아간다.
            return [.ready]
        case .failed:
            // 재시도는 업로드된 바이너리부터 다시 시작한다.
            return [.uploaded]
        }
    }

    public func canTransition(to next: VersionState) -> Bool {
        allowedNextStates.contains(next)
    }

    /// 파이프라인이 더 진행되지 않는 상태인지.
    public var isTerminal: Bool {
        self == .released || self == .failed
    }

    /// 스토어 앱 목록에 노출되는 상태인지.
    public var isPubliclyVisible: Bool {
        self == .released
    }
}

/// 서명 워커가 처리하는 잡의 상태.
public enum SigningJobState: String, Codable, Sendable, CaseIterable {
    /// 큐에서 워커를 기다린다.
    case queued
    /// 워커가 잡을 가져가 처리 중이다.
    case running
    case succeeded
    case failed
}
