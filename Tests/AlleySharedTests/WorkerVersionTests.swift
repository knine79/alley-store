import Testing

@testable import AlleyShared

/// 워커 버전을 견주는 규칙 (ADR-0042).
///
/// 문자열로 비교하면 `0.10.0` 이 `0.9.0` 보다 작다고 나온다. 그 실수는 조용해서,
/// 낡은 워커에 경고가 안 뜨거나 멀쩡한 워커가 계속 자기를 갈아끼우려 한다.
@Suite("워커 버전 견주기")
struct WorkerVersionTests {
    @Test("자릿수를 숫자로 읽는다")
    func readsParts() {
        #expect(WorkerVersion.parts(of: "1.2.3") == [1, 2, 3])
        #expect(WorkerVersion.parts(of: "0") == [0])
    }

    @Test("숫자가 아니면 읽지 않는다", arguments: ["", "1.2.x", "v1.2.3", "1..2", "-1.0"])
    func rejectsNonNumeric(value: String) {
        #expect(WorkerVersion.parts(of: value) == nil)
    }

    /// 이것이 문자열 비교였다면 반대로 나온다.
    @Test("열 자리가 아홉 자리보다 크다")
    func comparesNumerically() {
        #expect(WorkerVersion.isOlder("0.9.0", than: "0.10.0"))
        #expect(!WorkerVersion.isOlder("0.10.0", than: "0.9.0"))
    }

    @Test("자릿수가 달라도 견준다")
    func comparesDifferentLengths() {
        #expect(WorkerVersion.isOlder("1.2", than: "1.2.1"))
        #expect(!WorkerVersion.isOlder("1.2.0", than: "1.2"))
        #expect(!WorkerVersion.isOlder("1.2", than: "1.2.0"))
    }

    @Test("같으면 낡지 않았다")
    func equalIsNotOlder() {
        #expect(!WorkerVersion.isOlder("1.2.3", than: "1.2.3"))
    }

    /// **모르면 경고하지 않는다.** 형식이 낯설다고 낡았다고 단정하면, 다음에 버전
    /// 규칙을 바꿀 때 멀쩡한 워커가 전부 빨갛게 뜬다.
    @Test("못 읽는 값은 판단하지 않는다")
    func unknownIsNotJudged() {
        #expect(!WorkerVersion.isOlder("nightly", than: "1.0.0"))
        #expect(!WorkerVersion.isOlder("1.0.0", than: "nightly"))
    }

    /// 빌드 스크립트가 이 값을 읽어 번들에 박는다. 형식이 깨지면 빌드가 멈춘다.
    @Test("현재 버전은 견줄 수 있는 형식이다")
    func currentIsComparable() {
        #expect(WorkerVersion.parts(of: WorkerVersion.current) != nil)
    }
}
