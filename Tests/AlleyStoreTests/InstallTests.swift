import AlleyShared
import CryptoKit
import Foundation
import Testing

@testable import AlleyStoreCore

/// 임시 디렉터리에 가짜 앱을 만든다.
struct AppFixture: ~Copyable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// `Info.plist` 를 갖춘 `.app` 을 만든다.
    @discardableResult
    func makeApp(
        named name: String,
        bundleID: String,
        shortVersion: String? = "1.0.0",
        build: String? = "1"
    ) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )

        var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let shortVersion { plist["CFBundleShortVersionString"] = shortVersion }
        if let build { plist["CFBundleVersion"] = build }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func makeFile(_ name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}

@Suite("설치된 앱 찾기")
struct InstalledAppsTests {
    @Test("Info.plist 에서 번들 ID 와 빌드 번호를 읽는다")
    func readsBundleInfo() throws {
        let fixture = try AppFixture()
        let app = try fixture.makeApp(named: "메모장", bundleID: "com.example.notes", build: "42")

        let installed = try #require(InstalledApps.read(bundle: app))
        #expect(installed.bundleID == "com.example.notes")
        #expect(installed.buildNumber == 42)
        #expect(installed.shortVersion == "1.0.0")
    }

    @Test("Info.plist 가 없으면 앱으로 세지 않는다")
    func ignoresBundlesWithoutInfo() throws {
        let fixture = try AppFixture()
        let broken = fixture.root.appendingPathComponent("깨진.app", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        #expect(InstalledApps.read(bundle: broken) == nil)
    }

    @Test("숫자가 아닌 빌드 번호는 없는 것으로 본다")
    func ignoresNonNumericBuild() throws {
        let fixture = try AppFixture()
        // 형식이 강제되지 않는 값이라 이런 앱이 실제로 있다.
        let app = try fixture.makeApp(named: "이상한", bundleID: "com.example.odd", build: "1.2.3")

        #expect(InstalledApps.read(bundle: app)?.buildNumber == nil)
    }

    @Test("먼저 훑은 디렉터리가 이긴다")
    func earlierDirectoryWins() throws {
        let shared = try AppFixture()
        let personal = try AppFixture()
        try shared.makeApp(named: "메모장", bundleID: "com.example.notes", build: "10")
        try personal.makeApp(named: "메모장", bundleID: "com.example.notes", build: "5")

        // /Applications 를 먼저 넘긴다. 같은 앱이 두 곳에 있으면 그쪽이 진짜다.
        let found = InstalledApps.scan(directories: [shared.root, personal.root])
        #expect(found["com.example.notes"]?.buildNumber == 10)
    }

    @Test("없는 디렉터리는 조용히 넘어간다")
    func toleratesMissingDirectory() {
        // ~/Applications 는 없는 맥이 흔하다.
        let missing = URL(fileURLWithPath: "/이런/경로는/없다")
        #expect(InstalledApps.scan(directories: [missing]).isEmpty)
    }
}

@Suite("설치 상태 판단")
struct InstallStateTests {
    private func installed(build: Int?) -> InstalledApp {
        InstalledApp(
            bundleID: "com.example.notes",
            shortVersion: "1.0.0",
            buildNumber: build,
            location: URL(fileURLWithPath: "/Applications/메모장.app")
        )
    }

    @Test("깔려 있지 않으면 설치")
    func notInstalled() {
        #expect(InstallState.compare(installed: nil, releasedBuild: 3) == .notInstalled)
    }

    /// 개발자·관리자에게는 출시 전 앱도 목록에 내려간다 (`AppController.list`).
    /// 그때 "설치되지 않음" 이라고 적으면 설치할 수 있는데 안 한 것처럼 읽히는데,
    /// 정작 누를 버튼은 없다. 받을 것이 없다는 사실을 그대로 말해야 한다.
    @Test("출시본이 없으면 설치되지 않음이 아니라 출시본 없음")
    func notReleased() {
        #expect(InstallState.compare(installed: nil, releasedBuild: nil) == .notReleased)
        #expect(InstallState.notReleased.summary == "출시본 없음")
    }

    @Test("빌드 번호가 낮으면 업데이트")
    func older() {
        #expect(InstallState.compare(installed: installed(build: 2), releasedBuild: 3)
            == .updateAvailable)
    }

    @Test("같으면 최신")
    func same() {
        #expect(InstallState.compare(installed: installed(build: 3), releasedBuild: 3) == .upToDate)
    }

    @Test("깔려 있는 것이 더 높으면 그렇다고 말한다")
    func ahead() {
        // 개발자가 로컬 빌드를 직접 넣어둔 경우다. 업데이트라고 하면 거짓말이 된다.
        #expect(InstallState.compare(installed: installed(build: 9), releasedBuild: 3) == .ahead)
    }

    // MARK: - 번들 값으로 견주기 (ADR-0066)

    private func installed(bundleVersion: String?, shortVersion: String? = "1.0.0") -> InstalledApp {
        InstalledApp(
            bundleID: "com.example.notes",
            shortVersion: shortVersion,
            buildNumber: bundleVersion.flatMap(Int.init),
            location: URL(fileURLWithPath: "/Applications/메모장.app"),
            bundleVersion: bundleVersion
        )
    }

    private func released(build: Int = 1, bundleVersion: String?, shortVersion: String = "1.0.0") -> VersionDTO {
        VersionDTO(
            id: UUID(), appID: UUID(), shortVersion: shortVersion, buildNumber: build,
            bundleVersion: bundleVersion, state: .released, createdAt: Date()
        )
    }

    @Test("CFBundleVersion 에 점이 있어도 같으면 최신이다")
    func dottedBundleVersionMatches() {
        // 근무 체크 도우미가 이랬다. 스토어의 빌드 번호는 1, 번들은 1.8.25.
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "1.8.25"),
            released: released(build: 1, bundleVersion: "1.8.25")
        ) == .upToDate)
    }

    @Test("CFBundleVersion 을 앞에서부터 숫자로 견준다")
    func dottedBundleVersionOrders() {
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "1.8.25"),
            released: released(bundleVersion: "1.8.100")
        ) == .updateAvailable)
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "1.9"),
            released: released(bundleVersion: "1.8.25")
        ) == .ahead)
        // 모자란 자리는 0 이다.
        #expect(InstallState.order("1.8", "1.8.0") == .upToDate)
    }

    @Test("스토어가 매긴 빌드 번호가 아니라 번들 값을 믿는다")
    func prefersBundleVersionOverStoreBuild() {
        // 정수 번들이라도 스토어가 1 을 매겼으면, 빌드 번호로는 "깔린 것이 더 새롭다" 가 된다.
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "250"),
            released: released(build: 1, bundleVersion: "250")
        ) == .upToDate)
    }

    @Test("서버가 번들 값을 모르면 버전 문자열로 견준다")
    func fallsBackToShortVersion() {
        // 이 칸이 생기기 전에 서명한 출시본이다. 다시 올리지 않아도 "열기" 가 돼야 한다.
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "1.8.25", shortVersion: "1.8.25"),
            released: released(build: 1, bundleVersion: nil, shortVersion: "1.8.25")
        ) == .upToDate)
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "1.8.25", shortVersion: "1.8.25"),
            released: released(build: 2, bundleVersion: nil, shortVersion: "1.8.26")
        ) == .updateAvailable)
    }

    @Test("서버가 번들 값을 모르고 깔린 쪽이 정수면 예전처럼 빌드 번호로 견준다")
    func keepsIntegerPathForOldVersions() {
        // 스토어 앱 자신이 그렇다. 올릴 때 `--build` 를 번들 값과 맞춘다.
        #expect(InstallState.compare(
            installed: installed(bundleVersion: "26"),
            released: released(build: 27, bundleVersion: nil)
        ) == .updateAvailable)
    }

    @Test("숫자로 읽을 수 없으면 짐작하지 않는다")
    func nonNumericIsUnknown() {
        #expect(InstallState.order("1.0-beta", "1.0") == .unknown)
    }

    @Test("비교할 수 없으면 그렇다고 말한다")
    func unknown() {
        #expect(InstallState.compare(installed: installed(build: nil), releasedBuild: 3) == .unknown)
        #expect(InstallState.compare(installed: installed(build: 1), releasedBuild: nil) == .unknown)
    }

    /// 최신인 앱의 줄에서 하려는 일은 받기가 아니라 열기다.
    @Test("최신이면 버튼이 앱을 연다")
    func upToDateOpens() {
        #expect(InstallState.upToDate.actionTitle == "열기")
        #expect(InstallState.upToDate.opensInstalledApp)
    }

    /// 더 새로운 것이 깔려 있을 때 누르면 출시본으로 내려간다. 여는 버튼처럼 보이면
    /// 그 일이 숨는다.
    @Test("더 최신이 깔려 있거나 비교할 수 없으면 다시 설치로 남긴다")
    func aheadAndUnknownStillReinstall() {
        for state in [InstallState.ahead, .unknown] {
            #expect(state.actionTitle == "다시 설치")
            #expect(!state.opensInstalledApp)
        }
        #expect(!InstallState.notInstalled.opensInstalledApp)
        #expect(!InstallState.updateAvailable.opensInstalledApp)
    }

    /// 깔린 것을 덮어쓰는 상태에서만 묻고, 무엇을 잃는지에 따라 말이 다르다.
    @Test("깔린 것을 덮어쓸 때만 묻는다")
    func asksOnlyWhenOverwritingInstalledApp() {
        #expect(InstallState.ahead.reinstallWarning == .downgrade)
        #expect(InstallState.unknown.reinstallWarning == .possibleDowngrade)
        #expect(InstallState.upToDate.reinstallWarning == .overwrite)
        for state in [InstallState.notInstalled, .notReleased, .updateAvailable] {
            #expect(state.reinstallWarning == nil)
        }
    }

    /// 견줄 수 없을 때 "내려간다" 고 단정하면 틀릴 수 있다.
    @Test("비교할 수 없으면 내려갈 수 있다고만 말한다")
    func possibleDowngradeDoesNotClaimDowngrade() {
        let warning = ReinstallWarning.possibleDowngrade
        #expect(warning.title.contains("수 있습니다"))
        let message = warning.message(installed: "2.0", released: "1.0.2 (빌드 3)")
        #expect(message.contains("2.0"))
        #expect(message.contains("1.0.2 (빌드 3)"))
        #expect(message.contains("수 있습니다"))
    }

    @Test("내려갈 때는 무엇이 무엇으로 바뀌는지 적는다")
    func downgradeNamesBothVersions() {
        let message = ReinstallWarning.downgrade.message(
            installed: "9.9.9 (빌드 99)", released: "1.0.2 (빌드 3)"
        )
        #expect(message.contains("9.9.9 (빌드 99)"))
        #expect(message.contains("1.0.2 (빌드 3)"))
    }

    @Test("같은 빌드를 다시 받을 때는 덮어쓴다는 것만 알린다")
    func overwriteIsShort() {
        let message = ReinstallWarning.overwrite.message(
            installed: "1.0.2 (빌드 3)", released: "1.0.2 (빌드 3)"
        )
        #expect(message == "이 맥에 있는 1.0.2 (빌드 3) 을(를) 덮어씁니다.")
    }

    /// 내려간 것을 "업데이트" 라고 적으면 거짓말이 된다. 받기 전 상태로 고른다.
    @Test("갈아끼운 뒤의 안내는 올렸는지 내렸는지를 따른다")
    func replacedMessageFollowsWhatHappened() {
        #expect(InstallState.updateAvailable.replacedMessage(appName: "메모장", version: "1.2")
            == "메모장 을(를) 1.2 로 업데이트했습니다.")
        #expect(InstallState.ahead.replacedMessage(appName: "메모장", version: "1.2")
            == "메모장 을(를) 1.2 로 되돌렸습니다.")
        for state in [InstallState.upToDate, .unknown] {
            #expect(state.replacedMessage(appName: "메모장", version: "1.2")
                == "메모장 을(를) 1.2 로 다시 설치했습니다.")
        }
    }
}

@Suite("설치 전 검증")
struct BundleVerifierTests {
    @Test("해시가 다르면 설치하지 않는다")
    func rejectsMismatchedHash() throws {
        let fixture = try AppFixture()
        let file = try fixture.makeFile("build.zip", bytes: Data("내용".utf8))

        #expect(throws: BundleVerifier.VerificationError.self) {
            try BundleVerifier.verifyHash(of: file, expected: String(repeating: "0", count: 64))
        }
    }

    @Test("해시가 같으면 통과한다")
    func acceptsMatchingHash() throws {
        let fixture = try AppFixture()
        let bytes = Data("내용".utf8)
        let file = try fixture.makeFile("build.zip", bytes: bytes)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        try BundleVerifier.verifyHash(of: file, expected: expected)
        // 서버가 대문자로 줘도 같은 것으로 본다.
        try BundleVerifier.verifyHash(of: file, expected: expected.uppercased())
    }

    @Test("서버가 해시를 모르면 대조를 건너뛴다")
    func skipsWhenServerHasNoHash() throws {
        let fixture = try AppFixture()
        let file = try fixture.makeFile("build.zip", bytes: Data("내용".utf8))

        // 웹 콘솔로 완성본을 올린 경우다(ADR-0012). 서명과 공증 검사가 남아 있다.
        try BundleVerifier.verifyHash(of: file, expected: nil)
        try BundleVerifier.verifyHash(of: file, expected: "")
    }

    @Test("codesign 출력에서 팀 식별자를 뽑는다")
    func parsesTeamIdentifier() {
        let output = """
            Executable=/Applications/메모장.app/Contents/MacOS/메모장
            Identifier=com.example.notes
            Format=app bundle with Mach-O universal
            Signature size=9000
            Authority=Developer ID Application: Example Inc. (ABCDE12345)
            TeamIdentifier=ABCDE12345
            Timestamp=2026. 8. 31.
            """
        #expect(BundleVerifier.teamIdentifier(fromCodesignOutput: output) == "ABCDE12345")
    }

    @Test("서명이 없으면 팀도 없다")
    func handlesUnsignedOutput() {
        let output = """
            Identifier=com.example.notes
            TeamIdentifier=not set
            """
        #expect(BundleVerifier.teamIdentifier(fromCodesignOutput: output) == nil)
        #expect(BundleVerifier.teamIdentifier(fromCodesignOutput: "") == nil)
    }

    @Test("팀이 다르면 막는다")
    func blocksDifferentTeam() {
        // 같은 번들 ID 를 쓰는 다른 팀의 앱으로 바꿔치기하는 경로를 끊는다.
        #expect(throws: BundleVerifier.VerificationError.self) {
            try BundleVerifier.verifyTeam(incoming: "ZZZZZ99999", installed: "ABCDE12345")
        }
    }

    @Test("비교할 것이 없으면 통과한다")
    func passesWhenNothingToCompare() throws {
        // 처음 설치하거나, 깔려 있는 것이 서명되지 않은 경우다.
        try BundleVerifier.verifyTeam(incoming: "ABCDE12345", installed: nil)
        try BundleVerifier.verifyTeam(incoming: nil, installed: "ABCDE12345")
        try BundleVerifier.verifyTeam(incoming: "ABCDE12345", installed: "ABCDE12345")
    }
}

@Suite("설치 위치")
struct InstallLocationTests {
    @Test("쓸 수 없으면 홈 아래로 물러선다")
    func fallsBackToHome() throws {
        let fixture = try AppFixture()

        // /Applications 에 쓸 수 있는 계정이면 그쪽이 나오고, 아니면 홈 아래가 나온다.
        // 어느 쪽이든 존재하고 쓸 수 있는 디렉터리여야 한다.
        let destination = try Installer.destinationDirectory(home: fixture.root)
        #expect(FileManager.default.isWritableFile(atPath: destination.path))
        #expect(
            destination.path == "/Applications"
                || destination.path == fixture.root.appendingPathComponent("Applications").path
        )
    }
}
