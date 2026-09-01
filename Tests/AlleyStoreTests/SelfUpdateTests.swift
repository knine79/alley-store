import Foundation
import Testing

@testable import AlleyStoreCore

@Suite("자기 업데이트 스크립트")
struct SelfUpdateScriptTests {
    private let replacement = URL(fileURLWithPath: "/tmp/새 것/Alley Store.app")
    private let destination = URL(fileURLWithPath: "/Applications/Alley Store.app")

    private var script: String {
        SelfUpdate.script(pid: 4242, replacement: replacement, destination: destination)
    }

    @Test("공백이 있는 경로를 따옴표로 감싼다")
    func quotesPaths() {
        // "Alley Store.app" 처럼 공백이 흔하다. 따옴표가 없으면 두 인자로 쪼개진다.
        #expect(script.contains("\"/Applications/Alley Store.app\""))
        #expect(script.contains("\"/tmp/새 것/Alley Store.app\""))
    }

    @Test("앱이 사라질 때까지 기다린다")
    func waitsForExit() {
        // 도는 앱을 덮어쓰면 코드 서명이 깨져 그 프로세스가 죽는다.
        #expect(script.contains("kill -0 4242"))
    }

    @Test("아직 살아 있으면 건드리지 않는다")
    func bailsOutIfStillRunning() {
        #expect(script.contains("exit 1"))
    }

    @Test("cp 가 아니라 ditto 로 옮긴다")
    func usesDitto() {
        // cp -r 은 .app 안의 심볼릭 링크와 확장 속성을 망가뜨려 서명을 깬다.
        #expect(script.contains("/usr/bin/ditto"))
        #expect(!script.contains("cp -r"))
    }

    @Test("실패하면 있던 것을 되돌린다")
    func restoresOnFailure() {
        // 새 것을 못 놓았는데 옛것도 지웠으면 앱이 사라진 채로 끝난다.
        #expect(script.contains("BACKUP"))
        #expect(script.contains("/usr/bin/ditto \"$BACKUP\""))
    }

    @Test("끝나면 다시 띄운다")
    func relaunches() {
        #expect(script.contains("/usr/bin/open"))
    }

    @Test("셸이 읽을 수 있는 스크립트다")
    func isValidShellScript() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-self-update-test-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // 문법이 틀린 스크립트를 띄우면 앱은 종료됐는데 교체는 안 되는 상태가 된다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@Suite("업데이트 감지")
struct UpdateDetectionTests {
    @Test("번들 밖에서 돌면 자기 업데이트를 하지 않는다")
    func requiresBundle() {
        // 테스트는 .app 번들이 아니라 xctest 안에서 돈다.
        // 개발 중에도 같은 상태이므로 조용히 넘어가야 한다.
        #expect(SelfUpdate.currentBundle() == nil)
    }
}
