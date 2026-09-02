import AlleyProcess
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
        /// Sparkle 용 EdDSA 서명. 키가 설정되지 않았으면 nil.
        public var edSignature: String?
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
        // 업로더가 준 plist 가 있으면 그것이 진실이다 (ADR-0020).
        let provided = job.entitlements.map { Data($0.utf8) }
        let declaredKeys = try await validate(bundle: bundle, provided: provided)

        var codesigningDetail = "서명 대상 \(targets.count)개"
        if declaredKeys.isEmpty {
            // 실패시키지 않는다. 네이티브 맥 앱은 대부분 정말로 권한이 필요 없다.
            // 다만 나중에 "왜 안 붙었나"를 물을 사람을 위해 잡 로그에 남긴다.
            codesigningDetail += "\n\n\(EntitlementsGuidance.noneProvided)"
        }
        await progress(.codesigning, codesigningDetail)
        for target in targets {
            try await sign(target, workspace: workspace, provided: provided)
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

        var output = try describe(result)
        output.edSignature = try sparkleSignature(for: result)

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

    /// 서명하기 전에 번들을 살펴본다. 실제로 붙게 될 권한 키를 돌려준다.
    ///
    /// 업로더가 plist 를 줬으면 그것이 기준이고, 안 줬으면 번들에 붙어 있는 것을 읽는다.
    /// 재서명이라면 후자가 맞다.
    @discardableResult
    private func validate(bundle: AppBundle, provided: Data?) async throws -> [String] {
        // `??` 의 오른쪽은 autoclosure 라 await 를 넣을 수 없다. 풀어서 쓴다.
        let declared: Data
        if let provided {
            declared = provided
        } else {
            declared = await Entitlements.read(of: bundle.url)
        }

        let keys = Entitlements.keys(fromPropertyList: declared)
        try Entitlements.validate(bundle: bundle.url, declaredKeys: keys)
        try requireJITForElectron(bundle: bundle, declaredKeys: keys)
        return keys
    }

    /// Electron 을 품었는데 JIT 권한이 없으면 서명하기 전에 멈춘다.
    ///
    /// 이대로 서명하면 **공증은 통과한다.** 실행만 안 된다. 그런 앱이 나가면 원인을
    /// 찾는 데 하루가 걸리므로 여기서 잡는다.
    ///
    /// **이 검사는 Electron 하나만 안다. 일반화되지 않는다.** JVM, Mono, 자체 JIT 를 쓰는
    /// 게임 엔진처럼 같은 이유로 깨지는 런타임을 전혀 잡지 못한다. 그런 앱은 여기를 조용히
    /// 통과한 뒤 사용자의 맥에서 죽는다. 다른 런타임까지 알아보게 만들려면 번들 안의
    /// 바이너리가 무엇을 링크했는지 봐야 하는데, 그건 이 검사가 감당할 범위를 넘는다.
    func requireJITForElectron(bundle: AppBundle, declaredKeys: [String]) throws {
        guard bundle.containsElectronFramework,
              !declaredKeys.contains(EntitlementsGuidance.jitKey)
        else {
            return
        }
        throw PipelineError.commandFailed(
            step: "번들 검사",
            detail: EntitlementsGuidance.missingJIT(bundle: bundle.url.lastPathComponent)
        )
    }

    /// 하나를 서명한다.
    private func sign(_ target: URL, workspace: URL, provided: Data?) async throws {
        var arguments = [
            "--force",
            "--sign", config.signingIdentity,
            // Developer ID 로 배포하려면 Hardened Runtime 이 필수다.
            "--options", "runtime",
            // 인증서가 만료돼도 서명이 유효하도록 Apple 타임스탬프를 받는다.
            "--timestamp",
        ]

        if let file = await entitlementsFile(for: target, provided: provided, workspace: workspace) {
            arguments += ["--entitlements", file.path]
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

    /// 이 대상에 붙일 권한 파일. 붙일 것이 없으면 nil.
    ///
    /// **업로더가 준 plist 는 `.app` 번들에만 붙인다.** 메인 앱과 그 안의 헬퍼 `.app` 이
    /// 여기 해당한다. `--entitlements` 는 번들의 주 실행 파일에 쓰는 것이고, 프레임워크나
    /// dylib, 홀로 놓인 헬퍼 실행 파일에 붙이면 안 된다. Electron 을 서명하는 표준
    /// 도구(@electron/osx-sign)도 비샌드박스 Developer ID 타깃에서는 헬퍼 앱들에 메인과
    /// 같은 권한을 쓴다.
    ///
    /// 업로더가 줬는데 번들에도 권한이 붙어 있으면 **업로더가 준 것이 이긴다.** 명시적으로
    /// 준 것이 서명에서 읽어 짐작한 것보다 우선이다.
    ///
    /// 준 것이 없으면 붙어 있던 권한을 꺼내 다시 넘긴다. 넘기지 않으면 재서명 과정에서
    /// 권한이 사라지고, 앱은 실행되지만 그 기능만 조용히 죽는다.
    private func entitlementsFile(
        for target: URL,
        provided: Data?,
        workspace: URL
    ) async -> URL? {
        let data: Data
        if let provided, target.pathExtension == "app" {
            data = provided
        } else {
            data = await Entitlements.read(of: target)
        }

        let file = workspace.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        return Entitlements.writePropertyList(data, to: file)
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
        try await assertNothingLeftAdHoc(in: bundle)
    }

    /// 우리가 서명하지 않고 지나친 코드가 남았는지 본다.
    ///
    /// `codesign --verify --deep --strict` 로는 이것을 잡을 수 없다. 프레임워크 안의
    /// dylib 이 링커가 붙인 ad-hoc 서명 그대로 남아 있어도 봉인은 멀쩡해서 "valid on
    /// disk" 가 나온다. 실제로 Electron 앱에서 그런 파일 다섯 개를 지나친 적이 있고,
    /// 그때도 이 검증은 통과했다.
    ///
    /// 그래서 번들 안의 Mach-O 를 직접 훑어 ad-hoc 으로 남은 것이 있는지 센다.
    /// Developer ID 로 서명하는 한 ad-hoc 은 하나도 남으면 안 된다. 남았다면 그것은
    /// 우리가 대상에서 빠뜨렸다는 뜻이고, 공증에서 거절당한다.
    private func assertNothingLeftAdHoc(in bundle: AppBundle) async throws {
        var leftovers: [String] = []
        for code in bundle.allMachOFiles() {
            let result = await Shell.runDetached(
                "/usr/bin/codesign", ["-dv", code.path], timeout: 60
            )
            // codesign 은 이 정보를 표준 오류로 낸다.
            guard result.combinedOutput.contains("adhoc") else { continue }
            leftovers.append(code.path.replacingOccurrences(of: bundle.url.path + "/", with: ""))
        }
        guard leftovers.isEmpty else {
            throw PipelineError.commandFailed(
                step: "서명 검증",
                detail: """
                    서명되지 않고 남은 코드가 있습니다. 공증에서 거절됩니다:
                    \(leftovers.joined(separator: "\n"))
                    """
            )
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

    /// Sparkle 이 요구하는 서명. 키가 없으면 만들지 않는다.
    ///
    /// 키가 있는데 서명에 실패하면 잡 전체를 실패시킨다. 서명 없는 결과물을 올리면
    /// appcast 를 쓰는 앱이 조용히 업데이트를 못 받게 되고, 그건 나중에 원인을 찾기
    /// 가장 어려운 종류의 실패다.
    private func sparkleSignature(for file: URL) throws -> String? {
        guard let key = config.sparklePrivateKey else { return nil }
        return try SparkleSignature.sign(file: file, privateKeyBase64: key)
    }

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
            size: size,
            edSignature: nil
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
