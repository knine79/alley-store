import AlleyProcess
import AlleyShared
import Crypto
import Foundation

/// 워커가 스스로를 갈아끼운다 (ADR-0042).
///
/// 워커를 고쳐도 사람이 각 맥에 가서 다시 설치해야 했다. 그래서 dmg 를 모르는 워커가
/// 한참 돌면서 dmg 를 zip 으로 풀다 "번들 구조 문제" 라는 엉뚱한 진단을 내놨다.
///
/// **일이 없을 때만 갈아끼운다.** 서명이나 공증 도중에 프로세스가 바뀌면 그 잡이
/// 중간에 끊긴다. 공증은 Apple 응답을 기다리는 구간이 길어서 그럴 확률이 낮지 않다.
public struct SelfUpdate: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// 갈아끼웠다. 부르는 쪽이 프로세스를 끝내면 launchd 가 새것을 띄운다.
        case replaced(version: String)
        /// 할 일이 없다. 서버에 릴리스가 없거나 이미 같거나 더 높다.
        case upToDate
        /// 하지 않았다. 왜인지는 로그로 남긴다.
        case skipped(reason: String)
    }

    public enum UpdateError: Error, CustomStringConvertible {
        case downloadFailed(status: Int)
        case hashMismatch(expected: String, actual: String)
        case bundleMissing
        case notOurBundle(reason: String)
        case selfTestFailed(output: String)

        public var description: String {
            switch self {
            case .downloadFailed(let status):
                return "워커 번들을 내려받지 못했습니다 (\(status))."
            case .hashMismatch(let expected, let actual):
                return "받은 파일이 올린 파일과 다릅니다. 기대: \(expected), 실제: \(actual)"
            case .bundleMissing:
                return "받은 zip 안에 `.app` 이 없습니다."
            case .notOurBundle(let reason):
                return "받은 번들을 믿을 수 없습니다: \(reason)"
            case .selfTestFailed(let output):
                return "새 워커가 자기 점검을 통과하지 못했습니다: \(output)"
            }
        }
    }

    private let config: WorkerConfig
    private let client: WorkerClient
    private let log: @Sendable (String) -> Void

    public init(
        config: WorkerConfig,
        client: WorkerClient,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.config = config
        self.client = client
        self.log = log
    }

    /// 지금 돌고 있는 번들. `…/alley-worker.app/Contents/MacOS/alley-worker` 에서 거슬러 올라간다.
    ///
    /// 번들 밖에서 실행 중이면(개발 중 `swift run`) nil 이고, 그때는 갈아끼우지 않는다.
    public static func runningBundle(
        executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    ) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else {
            return nil
        }
        return bundle
    }

    /// 새 릴리스가 있으면 받아서 갈아끼운다.
    ///
    /// 돌려준 값이 `.replaced` 면 **부르는 쪽이 프로세스를 끝내야 한다.** 여기서
    /// `exit` 하지 않는 이유는, 끝내는 시점을 루프가 정해야 하기 때문이다.
    public func runIfNeeded() async -> Outcome {
        guard let bundle = Self.runningBundle() else {
            return .skipped(reason: "번들 밖에서 돌고 있어 갈아끼우지 않습니다.")
        }

        let release: WorkerReleaseDTO?
        do {
            release = try await client.currentRelease()
        } catch {
            return .skipped(reason: "릴리스를 조회하지 못했습니다: \(error)")
        }
        guard let release else { return .upToDate }
        guard WorkerVersion.isOlder(WorkerVersion.current, than: release.version) else {
            return .upToDate
        }

        log("새 워커 \(release.version) 를 받습니다. 지금은 \(WorkerVersion.current) 입니다.")
        do {
            try await replace(bundle: bundle, with: release)
            return .replaced(version: release.version)
        } catch {
            // 실패해도 계속 돈다. 갈아끼우지 못한 워커는 낡았을 뿐이고, 멈춘 워커는
            // 큐를 쌓는다. 둘 중 나쁜 쪽은 후자다.
            return .skipped(reason: "\(error)")
        }
    }

    // MARK: - 갈아끼우기

    private func replace(bundle: URL, with release: WorkerReleaseDTO) async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-worker-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archive = workspace.appendingPathComponent("worker.zip")
        try await download(release, to: archive)

        // 받은 것이 올린 그것인지 본다. 스토리지가 중간에 바뀌었거나 전송이 잘렸으면
        // 여기서 걸린다.
        let actual = try sha256(of: archive)
        guard actual == release.sha256 else {
            throw UpdateError.hashMismatch(expected: release.sha256, actual: actual)
        }

        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unzip = await Shell.runDetached(
            "/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], timeout: 300
        )
        guard unzip.succeeded else {
            throw UpdateError.bundleMissing
        }
        guard let newBundle = try topLevelApp(in: extracted) else {
            throw UpdateError.bundleMissing
        }

        try await requireTrustworthy(newBundle)
        try await selfTest(newBundle)

        // 여기서부터가 되돌리기 어려운 구간이다. 앞의 검사를 다 지난 뒤에만 온다.
        let previous = bundle.deletingLastPathComponent()
            .appendingPathComponent(bundle.lastPathComponent + ".previous")
        try? FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: bundle, to: previous)
        do {
            try FileManager.default.moveItem(at: newBundle, to: bundle)
        } catch {
            // 새것을 못 놓았으면 옛것을 도로 세운다. 여기서 실패하면 워커가 사라진다.
            try? FileManager.default.moveItem(at: previous, to: bundle)
            throw error
        }
        log("워커를 \(release.version) 로 갈아끼웠습니다. 이전 번들은 \(previous.lastPathComponent) 에 둡니다.")
    }

    private func download(_ release: WorkerReleaseDTO, to file: URL) async throws {
        guard let url = URL(string: release.downloadURL) else {
            throw UpdateError.downloadFailed(status: 0)
        }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UpdateError.downloadFailed(status: status)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func topLevelApp(in directory: URL) throws -> URL? {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" }
    }

    /// **우리가 서명한 번들인가.**
    ///
    /// 이 검사가 이 기능에서 가장 중요하다. 받은 zip 을 그대로 실행 파일로 앉히는
    /// 일이라, 여기가 뚫리면 스토리지에 접근할 수 있는 누구나 워커 맥에서 코드를
    /// 돌릴 수 있다. presigned URL 을 믿는 것과는 다른 이야기다.
    private func requireTrustworthy(_ bundle: URL) async throws {
        let expected = SignatureInspection.teamID(fromSigningIdentity: config.signingIdentity)
        let inspection = await SignatureInspection.inspect(bundle: bundle, expectedTeamID: expected)
        guard inspection.isAlreadyDone else {
            throw UpdateError.notOurBundle(reason: inspection.reason)
        }
    }

    /// 새 번들을 한 번 띄워본다.
    ///
    /// **되돌리는 것을 옛 프로세스가 살아 있는 동안 한다.** 갈아끼운 뒤에 하트비트를
    /// 기다렸다 되돌리려면, 새것이 아예 못 뜰 때 되돌릴 주체가 없다. 그 맥은 사람이
    /// 잘 가지 않는 머신이라 그대로 멈춘다.
    ///
    /// 점검은 설정을 읽고 서버에 인증해 본다. 설정이 안 맞거나 토큰이 죽었거나 번들이
    /// 깨졌으면 여기서 드러난다.
    private func selfTest(_ bundle: URL) async throws {
        let executable = bundle
            .appendingPathComponent("Contents/MacOS/\(bundle.deletingPathExtension().lastPathComponent)")
        let result = await Shell.runDetached(executable.path, ["preflight"], timeout: 120)
        guard result.succeeded else {
            throw UpdateError.selfTestFailed(output: result.combinedOutput)
        }
    }
}
