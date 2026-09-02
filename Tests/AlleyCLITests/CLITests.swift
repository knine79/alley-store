import Foundation
import Testing

@testable import AlleyCLICore

@Suite("인자 파싱")
struct ArgumentsTests {
    private let values: Set<String> = ["version", "build"]
    private let flags: Set<String> = ["signed", "release"]

    @Test("값 옵션과 깃발을 가른다")
    func parsesValuesAndFlags() throws {
        let arguments = try Arguments(
            ["build/App.zip", "--version", "1.2.0", "--signed"],
            valueOptions: values,
            flagOptions: flags
        )

        #expect(arguments.positional == ["build/App.zip"])
        #expect(arguments.string("version") == "1.2.0")
        #expect(arguments.flag("signed"))
        #expect(!arguments.flag("release"))
    }

    @Test("값이 빠지면 알려준다")
    func complainsAboutMissingValue() {
        // --version 뒤에 아무것도 없으면 다음 인자를 값으로 삼키는 것이 흔한 버그다.
        #expect(throws: Arguments.ParseError.self) {
            try Arguments(["--version"], valueOptions: values, flagOptions: flags)
        }
    }

    @Test("모르는 옵션은 조용히 넘기지 않는다")
    func rejectsUnknownOption() {
        // 오타 난 옵션을 무시하면 사용자는 그 설정이 먹은 줄 안다.
        #expect(throws: Arguments.ParseError.self) {
            try Arguments(["--versionn", "1.0"], valueOptions: values, flagOptions: flags)
        }
    }

    @Test("숫자가 아닌 값을 거절한다")
    func rejectsNonNumeric() throws {
        let arguments = try Arguments(
            ["--build", "abc"], valueOptions: values, flagOptions: flags
        )
        #expect(throws: Arguments.ParseError.self) {
            try arguments.integer("build")
        }
    }
}

@Suite("upload 명령 해석")
struct UploadParsingTests {
    @Test("기본값으로 미서명 업로드를 만든다")
    func buildsDefaultOptions() throws {
        let options = try CLI.parseUpload(["build/App.zip", "--version", "1.2.0"])

        #expect(options.file.lastPathComponent == "App.zip")
        #expect(options.shortVersion == "1.2.0")
        // 빌드 번호를 안 주면 서버의 마지막 번호에 1을 더한다.
        #expect(options.buildNumber == nil)
        #expect(options.uploadKind == .unsigned)
        #expect(!options.releaseAfterUpload)
    }

    @Test("옵션을 전부 읽는다")
    func readsEveryOption() throws {
        let options = try CLI.parseUpload([
            "build/App.zip",
            "--version", "1.2.0",
            "--build", "42",
            "--app", "com.example.tool",
            "--notes", "검색이 빨라졌습니다.",
            "--min-os", "14.0",
            "--signed",
            "--release",
        ])

        #expect(options.buildNumber == 42)
        #expect(options.expectedBundleID == "com.example.tool")
        #expect(options.releaseNotes == "검색이 빨라졌습니다.")
        #expect(options.minimumOSVersion == "14.0")
        #expect(options.uploadKind == .signed)
        #expect(options.releaseAfterUpload)
    }

    @Test("파일이 없으면 알려준다")
    func requiresFile() {
        #expect(throws: CLI.UsageError.self) {
            try CLI.parseUpload(["--version", "1.2.0"])
        }
    }

    @Test("버전이 없으면 알려준다")
    func requiresVersion() {
        #expect(throws: CLI.UsageError.self) {
            try CLI.parseUpload(["build/App.zip"])
        }
    }

    @Test("파일을 여러 개 주면 거절한다")
    func rejectsMultipleFiles() {
        // 두 번째 인자가 옵션의 값이어야 했는데 흘러나온 경우가 대부분이다.
        #expect(throws: CLI.UsageError.self) {
            try CLI.parseUpload(["a.zip", "b.zip", "--version", "1.0.0"])
        }
    }
}

/// `--entitlements` 는 서버에 붙기 전에 걸러야 한다.
///
/// 파일이 없거나 plist 가 아닌 것은 서버 문제가 아니라 인자 실수다. CI 가 종료 코드로
/// 그 차이를 판단한다.
@Suite("entitlements 인자")
struct EntitlementsArgumentTests {
    /// 임시 파일을 만들고 쓰고 나면 지운다.
    private func withFile(_ contents: String, _ body: (String) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-entitlements-\(UUID().uuidString).plist")
        try Data(contents.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try body(file.path)
    }

    private let valid = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>com.apple.security.cs.allow-jit</key><true/></dict>
        </plist>
        """

    @Test("안 주면 nil 이다")
    func absentIsNil() throws {
        // 대부분의 앱은 안 준다.
        #expect(try CLI.readEntitlements(at: nil) == nil)
    }

    @Test("파일을 읽어 원문 그대로 싣는다")
    func readsFile() throws {
        try withFile(valid) { path in
            let options = try CLI.parseUpload([
                "build/App.zip", "--version", "1.2.0", "--entitlements", path,
            ])
            #expect(options.entitlements == valid)
        }
    }

    @Test("파일이 없으면 인자 실수로 끝낸다")
    func missingFileIsUsageError() {
        #expect(throws: CLI.UsageError.self) {
            try CLI.readEntitlements(at: "/없는/경로/app.entitlements")
        }
    }

    @Test("plist 가 아니면 인자 실수로 끝낸다")
    func malformedFileIsUsageError() throws {
        // 서명할 때가 되어서야 발견하면 왕복이 길다.
        try withFile("이건 plist 가 아닙니다") { path in
            #expect(throws: CLI.UsageError.self) {
                try CLI.readEntitlements(at: path)
            }
        }
    }

    @Test("잘못된 파일을 주면 종료 코드 2 로 끝난다")
    func exitsWithUsageCode() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-entitlements-\(UUID().uuidString).plist")
        try Data("이건 plist 가 아닙니다".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // 서버에 붙기도 전에 끝난다. 파이프라인이 재시도할 이유가 없는 실패다.
        let code = await CLI.run(
            arguments: ["upload", "build/App.zip", "--version", "1.2.0", "--entitlements", file.path],
            environment: [:],
            output: { _ in },
            complain: { _ in }
        )
        #expect(code == .usage)
    }
}

@Suite("CLI 설정")
struct CLIConfigTests {
    @Test("환경변수에서 읽는다")
    func loadsFromEnvironment() throws {
        let config = try CLIConfig.load(from: [
            "ALLEY_SERVER_URL": "store.example.com",
            "ALLEY_TOKEN": "alleyd_abc",
        ])

        #expect(config.serverURL.absoluteString == "https://store.example.com")
        #expect(config.token == "alleyd_abc")
    }

    @Test("없는 값을 알려준다", arguments: [
        ["ALLEY_TOKEN": "alleyd_abc"],
        ["ALLEY_SERVER_URL": "store.example.com"],
        [:],
    ])
    func complainsAboutMissing(_ environment: [String: String]) {
        // CI 는 사람이 앉아 있지 않다. 무엇이 빠졌는지 로그에 분명히 남아야 한다.
        #expect(throws: CLIConfig.ConfigError.self) {
            try CLIConfig.load(from: environment)
        }
    }

    @Test("주소를 다듬는다", arguments: [
        ("http://localhost:8080/", "http://localhost:8080"),
        ("  store.example.com  ", "https://store.example.com"),
    ])
    func normalizesAddress(_ raw: String, _ expected: String) {
        #expect(CLIConfig.normalize(serverAddress: raw)?.absoluteString == expected)
    }

    @Test("주소가 아니면 거절한다", arguments: ["", "ftp://store.example.com"])
    func rejectsBadAddress(_ raw: String) {
        #expect(CLIConfig.normalize(serverAddress: raw) == nil)
    }
}

@Suite("파일 해시")
struct DigestTests {
    @Test("올린 파일의 SHA-256 을 계산한다")
    func hashesFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-cli-\(UUID().uuidString).bin")
        try Data("내용".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let digest = try UploadCommand.sha256(of: file)
        // 서버가 이 값을 그대로 받아 스토어 앱의 설치 검증에 쓴다.
        #expect(digest.count == 64)
        #expect(digest == digest.lowercased())
    }
}

/// 출력을 모으는 자리.
///
/// 출력 클로저가 `@Sendable` 이라 지역 변수를 그대로 담을 수 없다.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var first: String? {
        lock.lock()
        defer { lock.unlock() }
        return lines.first
    }
}

@Suite("명령 실행")
struct CommandRunTests {
    @Test("명령이 없으면 사용법과 함께 2로 끝난다")
    func noCommandIsUsageError() async {
        let code = await CLI.run(arguments: [], output: { _ in }, complain: { _ in })
        // CI 가 종료 코드로 판단한다. 설정 실수는 재시도할 가치가 없다.
        #expect(code == .usage)
    }

    @Test("모르는 명령도 2로 끝난다")
    func unknownCommandIsUsageError() async {
        let code = await CLI.run(arguments: ["deploy"], output: { _ in }, complain: { _ in })
        #expect(code == .usage)
    }

    @Test("version 은 서버 없이 답한다")
    func versionNeedsNoServer() async {
        let printed = Recorder()
        let code = await CLI.run(
            arguments: ["version"],
            environment: [:],
            output: { printed.append($0) },
            complain: { _ in }
        )

        #expect(code == .success)
        #expect(printed.first?.contains("alley") == true)
    }

    @Test("설정이 없으면 서버를 부르기 전에 멈춘다")
    func missingConfigStopsEarly() async {
        let complaints = Recorder()
        let code = await CLI.run(
            arguments: ["whoami"],
            environment: [:],
            output: { _ in },
            complain: { complaints.append($0) }
        )

        #expect(code == .usage)
        #expect(complaints.first?.contains("ALLEY_SERVER_URL") == true)
    }
}
