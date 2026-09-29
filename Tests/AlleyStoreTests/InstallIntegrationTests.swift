import AlleyProcess
import Foundation
import Testing

@testable import AlleyStoreCore

/// 진짜 서명·공증된 번들로 설치 경로를 끝까지 돌린다.
///
/// **나머지 설치 테스트는 전부 순수 로직이다.** `Info.plist` 를 읽고, 빌드 번호를
/// 견주고, 어떤 판정이 나오는지 본다. 정작 받은 zip 을 풀고 서명을 확인하고 제자리에
/// 옮기는 자리는 한 번도 돌려본 적이 없었다. 그 자리가 `ditto`, `codesign`,
/// `spctl`, `FileManager.replaceItemAt` 을 부르는 곳이라 순수 로직으로는 대신
/// 확인할 수 없다.
///
/// **CI 에서는 건너뛴다.** Developer ID 인증서와 공증 자격증명이 있는 맥에서만
/// 만들 수 있는 번들이 필요하다. 그 번들의 경로를 `ALLEY_SIGNED_FIXTURE` 로 주면
/// 돈다. 서버에 올려 워커가 서명한 결과물을 그대로 쓰는 것이 가장 가깝다.
///
/// ```
/// ALLEY_SIGNED_FIXTURE=/path/to/signed.zip \
/// ALLEY_SIGNED_FIXTURE_SHA256=<서버가 알려준 해시> \
/// swift test --filter InstallIntegrationTests
/// ```
@Suite("설치 실기", .enabled(if: ProcessInfo.processInfo.environment["ALLEY_SIGNED_FIXTURE"] != nil))
struct InstallIntegrationTests {
    private var fixture: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALLEY_SIGNED_FIXTURE"]!)
    }

    private var expectedHash: String? {
        ProcessInfo.processInfo.environment["ALLEY_SIGNED_FIXTURE_SHA256"]
    }

    /// 작업할 임시 자리. 설치 목적지까지 여기 두어 `/Applications` 를 건드리지 않는다.
    private func withTemporary(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alley-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// 받은 zip 을 그대로 두고 복사본을 만든다. `prepare` 는 zip 옆에 풀기 때문에
    /// 원본 자리를 어지럽히지 않으려면 옮겨놓고 시작해야 한다.
    private func stagedArchive(in root: URL) throws -> URL {
        let copy = root.appendingPathComponent("download.zip")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    @Test("받은 zip 을 풀고 서명과 공증을 확인한다")
    func aRealBundlePassesEveryCheck() async throws {
        try await withTemporary { root in
            let archive = try stagedArchive(in: root)

            let bundle = try await Installer().prepare(
                archive: archive, expectedSHA256: expectedHash
            )

            #expect(bundle.pathExtension == "app")
            #expect(FileManager.default.fileExists(atPath: bundle.path))
            // 서명이 붙어 있어야 여기까지 온다. 한 번 더 눈으로 본다.
            let team = await BundleVerifier.teamIdentifier(of: bundle)
            #expect(team != nil)
        }
    }

    /// 서버가 알려준 해시와 다르면 풀기 전에 멈춰야 한다. 받는 도중에 바뀐 파일을
    /// 풀어서 서명을 보는 것은 이미 한 발 늦은 것이다.
    @Test("해시가 다르면 풀기 전에 멈춘다")
    func aWrongHashStopsBeforeExtracting() async throws {
        try await withTemporary { root in
            let archive = try stagedArchive(in: root)

            await #expect(throws: (any Error).self) {
                try await Installer().prepare(
                    archive: archive,
                    expectedSHA256: String(repeating: "0", count: 64)
                )
            }
        }
    }

    /// 서명이 없는 번들은 다른 맥에서 열리지 않는다. 받는 쪽에서 먼저 거른다.
    @Test("서명이 없는 번들은 거절한다")
    func anUnsignedBundleIsRejected() async throws {
        try await withTemporary { root in
            let app = root.appendingPathComponent("Unsigned.app/Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: app.appendingPathComponent("Unsigned").path,
                contents: Data("#!/bin/sh\necho hi\n".utf8)
            )
            let archive = root.appendingPathComponent("unsigned.zip")
            let zipped = await Shell.runDetached(
                "/usr/bin/ditto",
                ["-c", "-k", "--keepParent",
                 root.appendingPathComponent("Unsigned.app").path, archive.path],
                timeout: 60
            )
            #expect(zipped.succeeded)

            await #expect(throws: (any Error).self) {
                try await Installer().prepare(archive: archive, expectedSHA256: nil)
            }
        }
    }

    /// 이미 깔린 앱이 있으면 그 자리를 지킨다. 사용자가 옮겨둔 곳이 있으면 그곳이다.
    /// `/Applications` 를 건드리지 않고 이 갈래를 볼 수 있는 유일한 길이기도 하다.
    @Test("이미 있는 앱은 원래 자리에서 교체된다")
    func anExistingAppIsReplacedInPlace() async throws {
        try await withTemporary { root in
            // 먼저 한 번 풀어서 "이미 깔린 앱" 을 만든다.
            let seed = try stagedArchive(in: root)
            let first = try await Installer().prepare(archive: seed, expectedSHA256: expectedHash)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let applications = home.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            let installed = applications.appendingPathComponent(first.lastPathComponent)
            try FileManager.default.moveItem(at: first, to: installed)

            let existing = InstalledApp(
                bundleID: "com.example.installprobe",
                shortVersion: "1.0.0",
                buildNumber: 1,
                location: installed
            )
            let before = try FileManager.default
                .attributesOfItem(atPath: installed.path)[.modificationDate] as? Date

            // 같은 번들을 다시 설치한다. 원래 자리에 그대로 놓여야 한다.
            let again = root.appendingPathComponent("again.zip")
            try FileManager.default.copyItem(at: fixture, to: again)
            let result = try await Installer().install(
                archive: again, expectedSHA256: expectedHash, replacing: existing
            )

            #expect(result.replacedExisting)
            #expect(result.location == installed)
            #expect(FileManager.default.fileExists(atPath: installed.path))
            // 교체됐으니 같은 파일이 아니다.
            let after = try FileManager.default
                .attributesOfItem(atPath: installed.path)[.modificationDate] as? Date
            #expect(before != nil && after != nil)
        }
    }
}
