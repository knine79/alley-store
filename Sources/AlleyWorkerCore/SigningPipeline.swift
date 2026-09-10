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
        /// 번들이 스스로 밝히는 값. 서버가 등록된 값과 맞춘다 (ADR-0033).
        public var bundleMetadata: BundleMetadata?
    }

    public enum PipelineError: Error, CustomStringConvertible {
        /// 외부 명령이 실패했다.
        ///
        /// 갈래(`code`)를 던지는 자리에서 함께 넣는다. **나중에 `step` 문자열을 보고
        /// 되짚지 않으려고 그렇게 한다.** 문자열은 화면에 보이는 말이라 언제든 다듬게
        /// 되는데, 거기에 분류가 매달려 있으면 말을 고치는 순간 조용히 틀린다.
        case commandFailed(step: String, code: SigningFailureCode, detail: String)
        case notarizationRejected(detail: String)

        public var description: String {
            switch self {
            case .commandFailed(let step, _, let detail):
                return "\(step) 단계에서 실패했습니다.\n\(detail)"
            case .notarizationRejected(let detail):
                return "Apple 이 공증을 거절했습니다.\n\(detail)"
            }
        }

        public var failureCode: SigningFailureCode {
            switch self {
            case .commandFailed(_, let code, _): return code
            case .notarizationRejected: return .notarizationRejected
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

        // 확장자를 `.zip` 으로 박지 않는다. dmg 도 받으므로 이름과 내용이 어긋나면
        // 나중에 읽는 사람이 헷갈린다. 형식은 `ArtifactFormat` 이 내용을 보고 가른다.
        let downloaded = workspace.appendingPathComponent("upload")
        await progress(.downloading, nil)
        try await client.download(from: job.artifactDownloadURL, to: downloaded)

        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        let bundle = try await extractBundle(from: downloaded, into: extracted)

        await progress(.validating, "번들: \(bundle.url.lastPathComponent)")
        try requireAcceptableBundleIdentifier(of: bundle, for: job)
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
        // 서명·스테이플이 `Info.plist` 를 건드리지는 않지만, 실제로 내보내는 번들에서
        // 읽는 편이 낫다. 앞서 읽어두고 이 사이에 무엇이 달라졌다면 그것이 버그다.
        var metadata = bundle.metadata
        // 등록값이 확정된 앱에서는 번들 ID 를 보내지 않는다. 이미 대조해서 같다는
        // 것을 알고, 같은 값을 또 보내면 받는 쪽이 판단할 거리가 늘어난다.
        if job.appBundleIDPending != true { metadata.bundleIdentifier = nil }
        output.bundleMetadata = metadata.isEmpty ? nil : metadata

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
            // 푸는 데 실패한 zip 은 다시 풀어도 안 풀린다. 올린 파일 자체가 잘못됐다.
            throw PipelineError.commandFailed(
                step: "압축 풀기",
                code: Self.code(exitCode: result.exitCode, otherwise: .bundleLayoutInvalid),
                detail: result.combinedOutput
            )
        }
    }

    /// 올라온 아티팩트에서 `.app` 을 꺼낸다.
    ///
    /// zip 과 dmg 를 모두 받는다. 빌드 도구가 뱉는 것은 대개 dmg 인데, 그것만 받지
    /// 않으면 올리는 사람이 매번 마운트해서 `.app` 을 꺼내 다시 압축해야 한다
    /// (ADR-0032).
    func extractBundle(from archive: URL, into directory: URL) async throws -> AppBundle {
        switch ArtifactFormat.detect(at: archive) {
        case .zip:
            try await unzip(archive, into: directory)
            return try AppBundle.locate(in: directory)
        case .diskImage:
            return try await copyFromDiskImage(archive, into: directory)
        case .unknown:
            throw PipelineError.commandFailed(
                step: "압축 풀기",
                code: .bundleLayoutInvalid,
                detail: """
                    올린 파일이 zip 도 dmg 도 아닙니다. 앱을 담은 zip 이나 dmg 를 올리세요.
                    `.app` 은 디렉터리라 그대로 올릴 수 없습니다.
                    """
            )
        }
    }

    /// 디스크 이미지를 붙였다 떼면서 `.app` 을 복사해 나온다.
    ///
    /// **신뢰할 수 없는 이미지를 붙이는 자리다.** 다음을 지킨다.
    ///
    /// - `-readonly` 로 붙여 이미지 자체가 바뀌지 않게 한다
    /// - `-nobrowse` 로 Finder 에 뜨지 않게 한다. 워커 맥에 사람이 로그인해 있다
    /// - `-noautoopen` 으로 이미지 안의 것이 저절로 열리지 않게 한다
    /// - 마운트 지점을 우리가 정한 작업 디렉터리 안으로 못 박는다. `/Volumes` 에
    ///   붙이면 이름이 겹칠 때 남의 볼륨을 건드릴 수 있고, 잡이 여럿이면 서로 밟는다
    ///
    /// 붙인 것은 반드시 뗀다. 떼지 못하면 워커 맥에 마운트가 쌓이고, 그 상태로는
    /// 다음 잡의 마운트도 실패하기 시작한다.
    private func copyFromDiskImage(_ image: URL, into directory: URL) async throws -> AppBundle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mountPoint = directory.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = await Shell.runDetached(
            "/usr/bin/hdiutil",
            [
                "attach", image.path,
                "-mountpoint", mountPoint.path,
                "-readonly", "-nobrowse", "-noautoopen",
                // 검증을 건너뛴다. 무결성은 우리가 해시로 이미 확인했고, 큰 이미지에서
                // 이 단계가 몇 분씩 걸린다.
                "-noverify",
            ],
            timeout: 600
        )
        guard attach.succeeded else {
            throw PipelineError.commandFailed(
                step: "디스크 이미지 열기",
                code: Self.code(exitCode: attach.exitCode, otherwise: .bundleLayoutInvalid),
                detail: """
                    dmg 를 열지 못했습니다. 암호가 걸려 있거나 사용권 동의(SLA)를 \
                    요구하는 이미지는 받을 수 없습니다. 그런 이미지는 사람이 눌러줘야 \
                    붙는데 워커에는 눌러줄 사람이 없습니다. zip 으로 올리세요.

                    \(attach.combinedOutput)
                    """
            )
        }

        // 붙인 것은 반드시 뗀다. `defer` 는 async 를 기다리지 못해서 여기서는 쓸 수
        // 없다. 떼기 전에 작업 디렉터리가 지워지면 마운트가 워커 맥에 남는다.
        do {
            let found = try AppBundle.locate(in: mountPoint)

            // 마운트에서 바로 서명할 수 없다. 읽기 전용이고 떼고 나면 사라진다.
            // `ditto` 를 쓰는 이유는 zip 을 풀 때와 같다. 심볼릭 링크와 확장 속성을
            // 그대로 옮기는 것이 이것뿐이다.
            let destination = directory.appendingPathComponent(found.url.lastPathComponent)
            let copy = await Shell.runDetached(
                "/usr/bin/ditto", [found.url.path, destination.path], timeout: 600
            )
            guard copy.succeeded else {
                throw PipelineError.commandFailed(
                    step: "디스크 이미지에서 복사",
                    code: Self.code(exitCode: copy.exitCode, otherwise: .bundleLayoutInvalid),
                    detail: copy.combinedOutput
                )
            }
            await detach(mountPoint)
            return AppBundle(url: destination)
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    /// 마운트를 뗀다.
    ///
    /// 실패해도 던지지 않는다. 여기서 던지면 원래 실패 원인이 "떼지 못했습니다" 로
    /// 덮인다. 대신 로그에 남겨서 마운트가 쌓이는 것을 사람이 알아챌 수 있게 한다.
    private func detach(_ mountPoint: URL) async {
        let result = await Shell.runDetached(
            "/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], timeout: 120
        )
        if !result.succeeded {
            await progress(
                .validating,
                """
                디스크 이미지를 떼지 못했습니다: \(mountPoint.path)
                워커 맥에 마운트가 남았을 수 있습니다. 쌓이면 다음 잡의 마운트도 실패합니다.
                \(result.combinedOutput)
                """
            )
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
            // 우리가 만든 번들을 우리가 못 묶은 경우다. 디스크가 찼거나 서명 과정에서
            // 번들이 깨졌다는 뜻이라 어느 쪽인지 여기서는 알 수 없다.
            throw PipelineError.commandFailed(
                step: "압축",
                code: Self.code(exitCode: result.exitCode, otherwise: .unknown),
                detail: result.combinedOutput
            )
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

    /// 번들 ID 가 받아들일 만한지 본다. 서명 전에 한다.
    ///
    /// 두 갈래다.
    ///
    /// - 등록된 ID 가 있으면 **그것과 같은지** 본다 (ADR-0029)
    /// - 등록된 ID 가 임시값이면 **조직 정책에 맞는지** 본다 (ADR-0034)
    ///
    /// 임시값인 경우는 dmg 로 올렸을 때다. 브라우저가 디스크 이미지를 열 수 없어
    /// 등록 시점에 번들 ID 를 알 수 없고, 사람에게 손으로 적게 하지 않기로 했다.
    /// 그러면 대조할 것이 없으므로 **정책 검사가 그 자리를 대신한다.** 이것이 없으면
    /// 아무 앱이나 올려서 조직 Developer ID 로 서명받을 수 있다.
    func requireAcceptableBundleIdentifier(
        of bundle: AppBundle,
        for job: SigningJobDTO
    ) throws {
        guard job.appBundleIDPending == true else {
            try requireDeclaredBundleIdentifier(of: bundle, matches: job.appBundleID)
            return
        }
        try requireBundleIdentifierMatchesPolicy(of: bundle, for: job)
    }

    /// 번들이 밝히는 ID 가 조직의 접두어 정책에 맞는가.
    func requireBundleIdentifierMatchesPolicy(
        of bundle: AppBundle,
        for job: SigningJobDTO
    ) throws {
        guard let declared = bundle.bundleIdentifier else {
            throw PipelineError.commandFailed(
                step: "번들 검사",
                code: .bundleIdentifierMismatch,
                detail: """
                    \(bundle.url.lastPathComponent) 의 Info.plist 에 CFBundleIdentifier 가 \
                    없습니다. 번들 ID 가 없는 앱은 스토어 앱이 설치 여부를 판단할 수 없어 \
                    배포해도 업데이트가 잡히지 않습니다.
                    """
            )
        }

        guard let prefix = job.requiredBundleIDPrefix, !prefix.isEmpty else { return }
        guard declared != prefix, !declared.hasPrefix(prefix + ".") else { return }

        // 정책이 "권장" 이면 막지 않는다. 서버가 그렇게 정해서 보냈다.
        guard job.enforceBundleIDPrefix == true else { return }

        throw PipelineError.commandFailed(
            step: "번들 검사",
            code: .bundleIdentifierMismatch,
            detail: """
                올린 앱의 번들 ID 는 \(declared) 인데, 이 스토어는 \(prefix). 로 시작하는 \
                앱만 받습니다. 서명하지 않고 멈췄습니다.

                이 앱을 정말 여기서 배포해야 한다면 관리자에게 번들 ID 규칙을 확인하세요.
                """
        )
    }

    /// 올린 번들이 스스로 밝히는 번들 ID 가 등록된 앱과 같은지 본다.
    ///
    /// **서명 전에** 본다. 여기를 통과시키면 남의 앱이나 엉뚱한 빌드가 조직의
    /// Developer ID 로 서명되고 공증까지 받는다. 그건 되돌릴 수 없다. Apple 이 발급한
    /// 공증 티켓은 회수할 수 없고, 그 사이 누가 받아갔는지도 알 수 없다.
    ///
    /// 서명이 되고 나서야 드러나는 두 번째 피해도 있다. 스토어 앱은 설치된 앱을
    /// `CFBundleIdentifier` 로 찾는다(`InstalledApps`). 등록된 ID 와 실제 번들의 ID 가
    /// 어긋난 채 배포되면 업데이트가 영영 감지되지 않는다. 그 앱은 스토어에 보이지만
    /// 사용자 머신에서는 "설치 안 됨"으로 남는다.
    ///
    /// `Info.plist` 에 번들 ID 가 아예 없으면 실패로 다룬다. 대조할 것이 없다는 뜻이고,
    /// 그런 번들은 스토어 앱이 어차피 찾지 못한다. 여기서 관대하게 넘기면 서명은
    /// 되지만 배포 후에 쓸 수 없는 앱이 된다.
    func requireDeclaredBundleIdentifier(
        of bundle: AppBundle,
        matches registered: String
    ) throws {
        guard let declared = bundle.bundleIdentifier else {
            throw PipelineError.commandFailed(
                step: "번들 검사",
                code: .bundleIdentifierMismatch,
                detail: """
                    \(bundle.url.lastPathComponent) 의 Info.plist 에 CFBundleIdentifier 가 \
                    없습니다. 등록된 번들 ID 는 \(registered) 입니다. 번들 ID 가 없는 앱은 \
                    스토어 앱이 설치 여부를 판단할 수 없어 배포해도 업데이트가 잡히지 않습니다.
                    """
            )
        }

        guard declared == registered else {
            throw PipelineError.commandFailed(
                step: "번들 검사",
                code: .bundleIdentifierMismatch,
                detail: """
                    올린 번들은 자기 번들 ID 를 \(declared) 라고 밝히는데, 등록된 번들 ID 는 \
                    \(registered) 입니다. 서명하지 않고 멈췄습니다.
                    """
            )
        }
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
            code: .entitlementsRejected,
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
                code: Self.code(
                    exitCode: result.exitCode,
                    otherwise: Self.codesignCode(from: result.combinedOutput)
                ),
                detail: result.combinedOutput
            )
        }
    }

    /// `codesign` 이 실패한 이유가 identity 쪽인지 번들 쪽인지 좁힌다.
    ///
    /// **여기만은 명령의 출력 문자열을 본다.** `codesign` 은 인증서가 없는 것과 번들이
    /// 깨진 것에 같은 종료 코드 1 을 쓴다. 무엇이 문제였는지는 사람에게 하는 말에만
    /// 들어 있어서, 그 말을 보지 않고서는 둘을 나눌 방법이 없다.
    ///
    /// **한계를 분명히 적어둔다.** Apple 이 이 문구를 바꾸면 이 판단은 아무 신호 없이
    /// 틀린다. 인증서가 만료됐는데도 `codesignFailed` 로 분류되고, 화면에는 번들을
    /// 고치라는 엉뚱한 안내가 나간다. 다만 **둘 다 재시도하지 않는 갈래라 재시도
    /// 판단은 틀어지지 않는다.** 잘못돼도 잘못되는 것은 안내 문장 하나다. 이 성질이
    /// 깨지지 않게, 두 코드 중 하나만 재시도 쪽으로 옮기는 일은 하지 말 것.
    static func codesignCode(from output: String) -> SigningFailureCode {
        let lowered = output.lowercased()
        let identityMarkers = [
            // 그 이름의 identity 가 키체인에 없다.
            "no identity found",
            "could not be found in the keychain",
            // 같은 이름의 identity 가 여러 개다.
            "ambiguous (matches multiple identities)",
            // 인증서 자체가 만료됐거나 유효하지 않다.
            "has expired",
            "certificate has expired",
        ]
        return identityMarkers.contains(where: lowered.contains)
            ? .signingIdentityUnavailable
            : .codesignFailed
    }

    /// 명령이 시간 초과로 끝났으면 그 갈래, 아니면 부르는 쪽이 정한 갈래.
    ///
    /// `Shell` 은 제한 시간을 넘긴 프로세스를 죽이고 124 를 돌려준다. 종료 코드로
    /// 알 수 있는 유일한 갈래라 여기서 한 번에 처리한다.
    static func code(
        exitCode: Int32,
        otherwise fallback: SigningFailureCode
    ) -> SigningFailureCode {
        exitCode == 124 ? .timedOut : fallback
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
            throw PipelineError.commandFailed(
                step: "서명 검증",
                code: Self.code(exitCode: result.exitCode, otherwise: .codesignFailed),
                detail: result.combinedOutput
            )
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
                code: .unsignedCodeRemains,
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
            // 제출이 접수돼 심사까지 갔는데 거절된 것만 "거절"이다. 그 판단은
            // `notarytool` 이 JSON 으로 주는 `status` 하나로 한다. 제출조차 못 했으면
            // 그 필드가 아예 없고, 그건 앱 내용과 무관한 실패라 다시 해볼 만하다.
            //
            // **`status` 값 자체는 Apple 이 정한다.** 그 문자열이 바뀌면 거절을 일시
            // 오류로 잘못 보고 세 번 제출하게 된다. 종료 코드로는 이 구분이 안 되므로
            // 다른 방법이 없다.
            //
            // `notarytool` man page 가 `--wait` 설명에서 값을 셋으로 못박고 있다:
            // "Accepted", "Invalid", "Rejected". 셋 다 다뤘다 (2026-09-02 확인).
            guard Self.isRejection(submission) else {
                throw PipelineError.commandFailed(
                    step: "공증 제출",
                    code: Self.code(exitCode: result.exitCode, otherwise: .appleServiceUnavailable),
                    detail: detail
                )
            }
            throw PipelineError.notarizationRejected(detail: detail)
        }
    }

    /// Apple 이 내용을 보고 물린 것인가.
    ///
    /// 제출 자체가 안 된 경우(네트워크, 자격증명, 서비스 장애)에는 제출 식별자도
    /// 상태도 없다. 그때는 거절이 아니다.
    static func isRejection(_ submission: NotarySubmission?) -> Bool {
        guard let status = submission?.status else { return false }
        return status == "Invalid" || status == "Rejected"
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
            // 스테이플은 Apple 서버에서 티켓을 받아 와야 한다. 공증이 방금 받아들여졌어도
            // 티켓이 아직 퍼지지 않았을 수 있어서, 잠시 뒤에 하면 되는 경우가 많다.
            throw PipelineError.commandFailed(
                step: "공증 티켓 첨부",
                code: Self.code(exitCode: result.exitCode, otherwise: .appleServiceUnavailable),
                detail: result.combinedOutput
            )
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
