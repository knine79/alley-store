import Foundation
import Testing

@testable import AlleyServer

/// 워커 목록의 macOS 열.
///
/// 이 표는 칸이 대부분 `nowrap` 이라 값 하나가 표의 폭을 그대로 밀어낸다. 워커가
/// 보내는 원문(`Version 26.6.2 (Build 25G83)`)을 그대로 적으면 표가 본문보다 넓어져
/// 가로로 밀린다.
@Suite("워커 목록의 macOS 값")
struct WorkerRowTests {
    @Test("Version 과 빌드 번호를 뗀다")
    func trimsVersionAndBuild() {
        #expect(WorkerRow.shortOSVersion("Version 26.6.2 (Build 25G83)") == "26.6.2")
    }

    @Test("한쪽만 있어도 뗀다")
    func trimsEitherSide() {
        #expect(WorkerRow.shortOSVersion("Version 26.2") == "26.2")
        #expect(WorkerRow.shortOSVersion("26.2 (Build 25C101)") == "26.2")
    }

    /// 다른 모양이 오면 아는 척하지 않는다. 원문이 낫다.
    @Test("모르는 모양은 그대로 둔다")
    func keepsUnknownShape() {
        #expect(WorkerRow.shortOSVersion("macOS 26.6.2 build 25G83") == "macOS 26.6.2 build 25G83")
    }

    @Test("알린 적 없으면 nil 그대로")
    func keepsNil() {
        #expect(WorkerRow.shortOSVersion(nil) == nil)
    }
}
