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

@Suite("갈아끼울 수 있는 자리인가")
struct SelfUpdateLocationTests {
    private func withBundle(_ body: (URL, URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-replace-\(UUID().uuidString)", isDirectory: true)
        let bundle = parent.appendingPathComponent("Alley Store.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer {
            // 권한을 되돌려야 지울 수 있다.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try body(parent, bundle)
    }

    @Test("쓸 수 있는 폴더의 번들은 갈아끼운다")
    func writableLocationIsReplaceable() throws {
        try withBundle { _, bundle in
            #expect(SelfUpdate.blocker(for: bundle) == nil)
        }
    }

    /// 번들을 지우고 새로 놓는 자리가 부모 폴더다. 번들만 쓸 수 있어서는 안 된다.
    /// MDM 이나 pkg 로 깔려 root 가 가진 경우가 이렇다. 이미 응용 프로그램 폴더에
    /// 있으니 거기로 옮기라고만 하면 막다른 말이 되고, 공유 폴더에서 연 경우처럼
    /// 옮기면 풀리는 때도 있어서 두 길을 함께 적는다.
    @Test("쓸 권한이 없으면 권한이 없다고 하고 할 수 있는 두 가지를 적는다")
    func noPermissionNamesBothWaysOut() throws {
        try withBundle { parent, bundle in
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
            #expect(SelfUpdate.blocker(for: bundle) == .noPermission)
            let message = SelfUpdate.Blocker.noPermission.message
            #expect(message.contains("권한"))
            #expect(message.contains("~/Applications"))
            #expect(message.contains("관리자"))
        }
    }

    /// 실제 읽기 전용 볼륨이다. 권한 비트가 아니라 마운트가 막는 경우를 본다.
    /// Translocation 도 읽기 전용 마운트라 같은 갈래로 떨어진다.
    @Test("읽기 전용 디스크 이미지 안이면 옮기라고 한다")
    func readOnlyVolumeAsksToMove() async throws {
        try withBundle { parent, bundle in
            // `-srcfolder` 는 폴더의 내용물을 볼륨 맨 위에 놓는다. 번들이 볼륨 안에
            // 번들로 놓이려면 그것을 담은 폴더를 넘겨야 한다.
            let stage = parent.appendingPathComponent("stage", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundle, to: stage.appendingPathComponent(bundle.lastPathComponent))
            let image = parent.appendingPathComponent("ro.dmg")
            let mount = parent.appendingPathComponent("mnt", isDirectory: true)
            let create = Process()
            create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            create.arguments = ["create", "-quiet", "-srcfolder", stage.path, "-format", "UDRO", image.path]
            try create.run()
            create.waitUntilExit()
            try #require(create.terminationStatus == 0)

            let attach = Process()
            attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            attach.arguments = ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, image.path]
            try attach.run()
            attach.waitUntilExit()
            try #require(attach.terminationStatus == 0)
            defer {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", "-quiet", "-force", mount.path]
                try? detach.run()
                detach.waitUntilExit()
            }

            let inside = mount.appendingPathComponent("Alley Store.app")
            // 없는 경로를 보면 "쓸 수 없다" 로 떨어져 무엇을 봐도 통과한다.
            try #require(FileManager.default.fileExists(atPath: inside.path))
            #expect(SelfUpdate.blocker(for: inside) == .readOnlyLocation)
        }
    }
}
