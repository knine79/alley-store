import AlleyShared
import Foundation
import Testing
import Vapor

@testable import AlleyServer

@Suite("버전 상태 전이")
struct VersionTransitionTests {
    private func makeVersion(state: VersionState, uploadKind: UploadKind = .unsigned) -> Version {
        let version = Version(
            appID: UUID(),
            shortVersion: "1.0.0",
            buildNumber: 1,
            uploadKind: uploadKind,
            createdByID: UUID(),
            state: state
        )
        return version
    }

    @Test("허용된 전이는 상태를 옮긴다")
    func allowedTransitionMovesState() throws {
        let version = makeVersion(state: .draft)
        try version.transition(to: .uploaded)
        #expect(version.state == .uploaded)
    }

    @Test("허용되지 않은 전이는 409 로 막는다")
    func forbiddenTransitionAborts() {
        let version = makeVersion(state: .draft)

        // draft 에서 바로 출시하면 바이너리 없는 버전이 배포된다.
        #expect(throws: Abort.self) {
            try version.transition(to: .released)
        }
        #expect(version.state == .draft, "실패한 전이가 상태를 바꾸면 안 된다")
    }

    @Test("같은 상태로는 넘어갈 수 없다", arguments: VersionState.allCases)
    func rejectsSelfTransition(_ state: VersionState) {
        let version = makeVersion(state: state)
        #expect(throws: Abort.self) {
            try version.transition(to: state)
        }
    }

    @Test("출시하면 시각이 남는다")
    func releaseStampsTime() throws {
        let version = makeVersion(state: .ready)
        #expect(version.releasedAt == nil)

        try version.transition(to: .released)
        #expect(version.releasedAt != nil)
    }

    @Test("실패하면 이유가 남는다")
    func failureKeepsReason() throws {
        let version = makeVersion(state: .signing)
        try version.transition(to: .failed, reason: "인증서를 찾지 못했습니다.")

        #expect(version.state == .failed)
        #expect(version.failureReason == "인증서를 찾지 못했습니다.")
    }

    @Test("재시도하면 지난 실패 이유가 지워진다")
    func retryClearsStaleFailure() throws {
        let version = makeVersion(state: .signing)
        try version.transition(to: .failed, reason: "공증 서버 응답 없음")
        try version.transition(to: .uploaded)

        // 남겨두면 성공한 버전에 실패 문구가 붙어 화면에 뜬다.
        #expect(version.failureReason == nil)
    }

    @Test("출시를 되돌려도 이미 만든 아티팩트는 그대로 쓴다")
    func unreleaseGoesBackToReady() throws {
        let version = makeVersion(state: .released)
        try version.transition(to: .ready)
        #expect(version.state == .ready)
    }

    @Test("아티팩트를 안 읽었으면 크기와 해시가 비어 있다")
    func dtoWithoutLoadedArtifacts() throws {
        let version = makeVersion(state: .ready)
        version.id = UUID()

        // 관계를 읽지 않은 채 DTO 를 만들면 Fluent 가 죽는 대신 nil 이 나와야 한다.
        let dto = try version.toDTO()
        #expect(dto.fileSize == nil)
        #expect(dto.sha256 == nil)
    }

    @Test("서명본이 있으면 그쪽을 내보낸다")
    func prefersSignedArtifact() throws {
        let version = makeVersion(state: .ready)
        let versionID = UUID()
        version.id = versionID

        version.$artifacts.value = [
            Artifact(versionID: versionID, kind: .unsigned, storageKey: "u.zip", sha256: "aaa", fileSize: 10),
            Artifact(versionID: versionID, kind: .signed, storageKey: "s.zip", sha256: "bbb", fileSize: 20),
        ]

        // 배포 대상은 서명·공증을 마친 쪽이다. 미서명본을 내보내면 Gatekeeper 가 막는다.
        let dto = try version.toDTO()
        #expect(dto.sha256 == "bbb")
        #expect(dto.fileSize == 20)
    }

    @Test("서명본이 아직 없으면 올린 그대로를 가리킨다")
    func fallsBackToUnsignedArtifact() throws {
        let version = makeVersion(state: .uploaded)
        let versionID = UUID()
        version.id = versionID
        version.$artifacts.value = [
            Artifact(versionID: versionID, kind: .unsigned, storageKey: "u.zip", sha256: "aaa", fileSize: 10)
        ]

        #expect(version.bestArtifact?.kind == .unsigned)
    }
}
