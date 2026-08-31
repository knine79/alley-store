import AlleyShared
import Crypto
import Foundation

/// 미서명 zip 하나를 받아 서명·공증·스테이플을 마친 zip 으로 만든다.
///
/// 순서가 규칙이다. 안쪽부터 서명하고(`AppBundle.codeToSign`), 공증은 서명이 끝난
/// 뒤에만 의미가 있고, 스테이플은 공증이 받아들여진 뒤에만 가능하다. 하나라도
/// 건너뛰면 사용자의 맥에서 Gatekeeper 경고가 뜬다.
///
/// 진행 상황은 단계마다 밖으로 알린다. 공증은 Apple 이 잡고 있는 시간이라
/// 몇 분에서 몇십 분이 걸리고, 그동안 아무 소식이 없으면 멈춘 것처럼 보인다.
public struct SigningPipeline: Sendable {
    /// 공증 제출 하나에 허용하는 시간.
    ///
    /// `notarytool --wait` 자체에도 같은 값을 넘긴다. Apple 쪽이 밀리면 30분을 넘기기도
    /// 하는데, 그때는 실패로 보고하고 다시 시도하는 편이 워커가 영원히 묶이는 것보다 낫다.
    static let notarizationTimeout: TimeInterval = 45 * 60

    public struct Output: Sendable {
        public var file: URL
        public var sha256: String
        public var size: Int64
    }

    public enum PipelineError: Error, CustomStringConvertible {
        case commandFailed(step: String, detail: String)
        case notarizationRejected(detail: String)

        public var description: String {
            switch self {
            case .commandFailed(let step, let detail):
                return "\(step) 단계에서 실패했습니다.\n\(detail)"
            case .notarizationRejected(let detail):
                return "Apple 이 공증을 거절했습니다.\n\(detail)"
            }
        }
    }

    private let config: WorkerConfig
    /// 단계가 바뀔 때마다 부른다. 서버에 보고하는 쪽이 이 자리를 채운다.
    private let progress: @Sendable (SigningPhase, String?) async -> Void

    public init(
        config: WorkerConfig,
        progress: @escaping @Sendable (SigningPhase, String?) async -> Void = { _, _ in }
    ) {
        self.config = config
        self.progress = progress
    }

    /// 잡 하나를 처음부터 끝까지 처리한다.
    ///
    /// 작업 디렉터리는 잡마다 새로 만들고 끝나면 지운다. 남겨두면 서명 대상이 섞이고,
    /// 무엇보다 앱 바이너리가 계속 쌓인다.
    public func run(job: SigningJobDTO, client: WorkerClient) async throws -> Output {
        let workspace = config.workDirectory
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let downloaded = workspace.appendingPathComponent("upload.zip")
        await progress(.downloading, nil)
        try await client.download(from: job.artifactDownloadURL, to: downloaded)

        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        try await unzip(downloaded, into: extracted)
        let bundle = try AppBundle.locate(in: extracted)

        await progress(.validating, "번들: \(bundle.url.lastPathComponent)")
        let targets = try bundle.codeToSign()
        try await validate(bundle: bundle)

        await progress(.codesigning, "서명 대상 \(targets.count)개")
        for target in targets {
            try await sign(target, workspace: workspace)
        }
        try await verifySignature(of: bundle)

        let notarizationInput = workspace.appendingPathComponent("notarize.zip")
        try await zip(bundle.url, into: notarizationInput)

        await progress(.notarizing, nil)
        try await notarize(notarizationInput)

        await progress(.stapling, nil)
        try await staple(bundle.url)

        await progress(.uploading, nil)
        let result = workspace.appendingPathComponent("signed.zip")
        try await zip(bundle.url, into: result)

        let output = try describe(result)
        try await client.upload(result, to: job.resultUploadURL)
        return output
    }

    // MARK: - 단계

    /// zip 을 푼다.
    ///
    /// `unzip` 이 아니라 `ditto` 를 쓴다. `.app` 은 디렉터리이고 그 안에는 심볼릭 링크와
    /// 확장 속성이 들어 있는데, `ditto` 만 그것을 그대로 복원한다. 링크가 실제 파일로
    /// 풀리면 서명이 깨진다.
    private func unzip(_ archive: URL, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = await Shell.runDetached(
            "/usr/bin/ditto",
            ["-x", "-k", archive.path, directory.path],
            timeout: 600
        )
        guard result.succeeded else {
            throw PipelineError.commandFailed(step: "압축 풀기", detail: result.combinedOutput)
        }
    }

    /// 배포용 zip 을 만든다.
    ///
    /// `--keepParent` 가 있어야 `.app` 이 최상위에 그대로 담긴다. 없으면 앱 안의
    /// `Contents` 만 풀려나온다.
    private func zip(_ bundle: URL, into archive: URL) async throws {
        try? FileManager.default.removeItem(at: archive)
        let result = await Shell.runDetached(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, archive.path],
            timeout: 600
        )
        guard result.succeeded else {
            throw PipelineError.commandFailed(step: "압축", detail: result.combinedOutput)
        }
    }

    private func validate(bundle: AppBundle) async throws {
        let declared = await Entitlements.read(of: bundle.url)
        try Entitlements.validate(
            bundle: bundle.url,
            declaredKeys: Entitlements.keys(fromPropertyList: declared)
        )
    }

    /// 하나를 서명한다.
    ///
    /// 붙어 있던 권한을 꺼내 다시 넘긴다. 넘기지 않으면 재서명 과정에서 권한이
    /// 사라지고, 앱은 실행되지만 그 기능만 조용히 죽는다.
    private func sign(_ target: URL, workspace: URL) async throws {
        var arguments = [
            "--force",
            "--sign", config.signingIdentity,
            // Developer ID 로 배포하려면 Hardened Runtime 이 필수다.
            "--options", "runtime",
            // 인증서가 만료돼도 서명이 유효하도록 Apple 타임스탬프를 받는다.
            "--timestamp",
        ]

        let entitlements = await Entitlements.read(of: target)
        let file = workspace.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        if let written = Entitlements.writePropertyList(entitlements, to: file) {
            arguments += ["--entitlements", written.path]
        }
        arguments.append(target.path)

        let result = await Shell.runDetached("/usr/bin/codesign", arguments, timeout: 600)
        guard result.succeeded else {
            throw PipelineError.commandFailed(
                step: "서명 (\(target.lastPathComponent))",
                detail: result.combinedOutput
            )
        }
    }

    /// 서명 결과를 스스로 확인한다.
    ///
    /// 공증에 올리기 전에 걸러낸다. Apple 에 제출했다가 거절당하면 왕복에 몇 분이 든다.
    private func verifySignature(of bundle: AppBundle) async throws {
        let result = await Shell.runDetached(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", bundle.url.path],
            timeout: 600
        )
        guard result.succeeded else {
            throw PipelineError.commandFailed(step: "서명 검증", detail: result.combinedOutput)
        }
    }

    private func notarize(_ archive: URL) async throws {
        let result = await Shell.runDetached(
            "/usr/bin/xcrun",
            [
                "notarytool", "submit", archive.path,
                "--keychain-profile", config.notaryProfile,
                "--wait",
                "--timeout", "\(Int(Self.notarizationTimeout))s",
                "--output-format", "json",
            ],
            timeout: Self.notarizationTimeout + 120
        )

        let submission = NotarySubmission(json: result.standardOutput)
        guard result.succeeded, submission?.status == "Accepted" else {
            var detail = result.combinedOutput
            // 거절 이유는 제출 로그에만 있다. 그것 없이는 무엇을 고쳐야 할지 알 수 없다.
            if let id = submission?.id, let log = await notarizationLog(id: id) {
                detail += "\n\n\(log)"
            }
            throw PipelineError.notarizationRejected(detail: detail)
        }
    }

    private func notarizationLog(id: String) async -> String? {
        let result = await Shell.runDetached(
            "/usr/bin/xcrun",
            ["notarytool", "log", id, "--keychain-profile", config.notaryProfile],
            timeout: 300
        )
        guard result.succeeded else { return nil }
        return result.standardOutput
    }

    /// 공증 티켓을 번들에 박는다.
    ///
    /// 이걸 해야 인터넷이 끊긴 맥에서도 Gatekeeper 가 통과시킨다. 안 하면 첫 실행에서
    /// Apple 서버 조회가 필요하다.
    private func staple(_ bundle: URL) async throws {
        let result = await Shell.runDetached(
            "/usr/bin/xcrun",
            ["stapler", "staple", bundle.path],
            timeout: 300
        )
        guard result.succeeded else {
            throw PipelineError.commandFailed(step: "공증 티켓 첨부", detail: result.combinedOutput)
        }
    }

    // MARK: - 결과

    /// 올릴 파일의 크기와 해시.
    ///
    /// 해시는 스토어 앱이 설치 직전에 대조한다. 파일을 통째로 메모리에 올리지 않도록
    /// 조각내어 읽는다. 수백 MB 짜리 앱에서 그 차이가 크다.
    private func describe(_ file: URL) throws -> Output {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }

        return Output(
            file: file,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            size: size
        )
    }
}

/// `notarytool` 이 JSON 으로 주는 제출 결과 중 우리가 쓰는 것.
struct NotarySubmission {
    var id: String?
    var status: String?

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        self.id = parsed["id"] as? String
        self.status = parsed["status"] as? String
    }
}
