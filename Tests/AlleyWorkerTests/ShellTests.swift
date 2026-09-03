import AlleyProcess
import Foundation
import Testing

@Suite("외부 명령 실행")
struct ShellTests {
    /// 아주 빨리 끝나는 명령을 여러 번 돌린다.
    ///
    /// 예전 구현은 `Process.waitUntilExit()` 로 종료를 기다렸는데, 자식이 그 호출이
    /// 시작되기 전에 끝나버리면 종료를 놓치고 영영 돌아오지 않았다. 실제로 워커가
    /// 300KB 를 올리는 `curl` 에서 멈춰 그 뒤로 아무 잡도 받지 못했다.
    ///
    /// 경합이라 한 번으로는 안 잡힌다. 여러 번 돌려야 드러난다.
    @Test("빨리 끝나는 명령에서 멈추지 않는다", .timeLimit(.minutes(1)))
    func doesNotHangOnFastCommands() async {
        for _ in 0..<40 {
            let result = await Shell.runDetached("/bin/echo", ["빠름"], timeout: 30)
            #expect(result.succeeded)
            #expect(result.standardOutput.contains("빠름"))
        }
    }

    @Test("종료 코드를 그대로 돌려준다", .timeLimit(.minutes(1)))
    func reportsExitCode() async {
        let ok = await Shell.runDetached("/usr/bin/true", [], timeout: 30)
        #expect(ok.exitCode == 0)

        let failed = await Shell.runDetached("/usr/bin/false", [], timeout: 30)
        #expect(failed.exitCode != 0)
        #expect(!failed.succeeded)
    }

    @Test("표준 오류도 모은다", .timeLimit(.minutes(1)))
    func collectsStandardError() async {
        let result = await Shell.runDetached(
            "/bin/sh", ["-c", "echo 나감; echo 오류 1>&2"], timeout: 30
        )
        #expect(result.standardOutput.contains("나감"))
        #expect(result.standardError.contains("오류"))
    }

    @Test("실행 파일이 없으면 127 로 알린다", .timeLimit(.minutes(1)))
    func reportsMissingExecutable() async {
        let result = await Shell.runDetached("/없는/명령", [], timeout: 30)
        #expect(result.exitCode == 127)
        #expect(!result.succeeded)
    }

    @Test("정해진 시간을 넘기면 끊는다", .timeLimit(.minutes(2)))
    func stopsAtTimeout() async {
        let started = Date()
        let result = await Shell.runDetached("/bin/sleep", ["60"], timeout: 2)

        // 끊었다는 것을 종료 코드로 알린다. 60초를 다 기다리지 않는다.
        #expect(result.exitCode == 124)
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("많은 출력을 내도 파이프에 막히지 않는다", .timeLimit(.minutes(1)))
    func handlesLargeOutput() async {
        // 파이프 버퍼(보통 64KB)를 훌쩍 넘겨야 의미가 있다.
        let result = await Shell.runDetached(
            "/bin/sh", ["-c", "for i in $(seq 1 20000); do echo 줄$i; done"], timeout: 30
        )
        #expect(result.succeeded)
        #expect(result.standardOutput.contains("줄20000"))
    }
}
