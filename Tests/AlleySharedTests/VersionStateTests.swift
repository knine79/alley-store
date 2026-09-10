import Testing

@testable import AlleyShared

@Suite("버전 상태 머신")
struct VersionStateTests {
    @Test("워커 대행 경로를 끝까지 통과한다")
    func walksUnsignedPipeline() {
        let pipeline: [VersionState] = [.draft, .uploaded, .signing, .notarizing, .ready, .released]
        for (current, next) in zip(pipeline, pipeline.dropFirst()) {
            #expect(current.canTransition(to: next), "\(current) → \(next) 전이가 막혀 있다")
        }
    }

    /// 서명을 건너뛸지는 워커가 번들을 열어보고 정한다. 건너뛰더라도 상태는
    /// `signing → notarizing → ready` 를 그대로 지난다 (ADR-0035).
    @Test("워커를 거치지 않고 배포 준비됨이 될 수 없다")
    func cannotReachReadyWithoutWorker() {
        #expect(!VersionState.uploaded.canTransition(to: .ready))
    }

    @Test("업로드 전에는 서명으로 갈 수 없다")
    func cannotSignBeforeUpload() {
        #expect(!VersionState.draft.canTransition(to: .signing))
        #expect(!VersionState.draft.canTransition(to: .ready))
    }

    @Test("파이프라인 단계를 건너뛰지 못한다")
    func rejectsSkippingPipelineStages() {
        #expect(!VersionState.signing.canTransition(to: .ready))
        #expect(!VersionState.signing.canTransition(to: .released))
        #expect(!VersionState.uploaded.canTransition(to: .released))
    }

    @Test("실패는 업로드된 바이너리부터 재시도한다")
    func retriesFromUploadedState() {
        #expect(VersionState.failed.canTransition(to: .uploaded))
        // 실패에서 곧바로 배포 가능 상태로 갈 수는 없다.
        #expect(!VersionState.failed.canTransition(to: .ready))
        #expect(!VersionState.failed.canTransition(to: .released))
    }

    @Test("출시를 되돌리면 비공개 상태로 돌아간다")
    func unreleaseReturnsToReady() {
        #expect(VersionState.released.canTransition(to: .ready))
    }

    @Test("어느 단계에서든 실패로 떨어질 수 있다")
    func anyActiveStageCanFail() {
        let failable: [VersionState] = [.draft, .uploaded, .signing, .notarizing, .ready]
        for state in failable {
            #expect(state.canTransition(to: .failed), "\(state) 에서 실패로 갈 수 없다")
        }
    }

    @Test("released 만 스토어 목록에 노출된다")
    func onlyReleasedIsVisible() {
        for state in VersionState.allCases {
            #expect(state.isPubliclyVisible == (state == .released))
        }
    }

    @Test("자기 자신으로는 전이하지 않는다")
    func rejectsSelfTransition() {
        for state in VersionState.allCases {
            #expect(!state.canTransition(to: state), "\(state) 가 자기 자신으로 전이된다")
        }
    }
}
