import AlleyShared
import Foundation

/// `alley` 명령의 뼈대.
///
/// 실행 타깃은 이것을 부르기만 한다. 로직이 라이브러리에 있어야 테스트가 닿는다.
public enum CLI {
    /// 제품 릴리스 버전을 그대로 쓴다. CLI 만의 버전을 따로 두면 어긋나고,
    /// 어긋나면 "어느 릴리스의 CLI 인가" 를 알 수 없다 (ADR-0043).
    public static let version = AlleyVersion.current

    public static let usage = """
        사용법: alley <command> [options]

        명령:
          auth login          브라우저를 열어 이 기기를 계정에 연결한다
          auth status         지금 무엇으로 붙어 있는지 본다
          auth logout         저장해둔 것을 지운다
          upload <파일.zip>   새 버전을 올린다
          versions            이 앱의 버전 목록을 본다
          whoami              이 토큰이 어느 앱의 것인지 본다
          mcp                 코딩 에이전트에게 스토어를 내준다 (MCP, stdio)
          version             alley 버전을 출력한다

        mcp 는 사람 토큰(alleyu_)으로 붙습니다. `alley auth login` 이 브라우저를 열어
        받아옵니다. 배포 토큰으로는 업로드밖에 되지 않습니다.

        upload 옵션:
          --version <문자열>   사람이 보는 버전. 필수 (예: 1.2.0)
          --build <숫자>       빌드 번호. 없으면 서버의 마지막 번호 + 1
          --app <번들 ID>      토큰이 이 앱의 것인지 확인한다
          --notes <문자열>     릴리즈 노트
          --min-os <문자열>    실행에 필요한 최소 macOS 버전 (예: 14.0)
          --entitlements <경로>
                               서명할 때 붙일 entitlements plist.
                               \(EntitlementsGuidance.whenNeeded)
          --signed             (더 이상 쓰이지 않음) 워커가 번들을 열어보고 판정한다
          --release            (더 이상 쓰이지 않음) 워커가 끝낸 뒤 콘솔에서 출시한다

        auth login 옵션:
          --server <주소>      붙을 스토어. 없으면 ALLEY_SERVER_URL 을 본다

        환경변수:
          ALLEY_SERVER_URL    스토어 서버 주소. 붙여둔 서버가 하나면 없어도 된다
          ALLEY_TOKEN         CI 가 쓰는 배포 토큰. 있으면 저장해둔 것보다 먼저다

        예시:
          alley auth login --server https://store.example.com
          alley upload build/MyApp.zip --version 1.2.0
          alley upload build/MyApp.zip --version 1.2.0 --entitlements build/app.entitlements
        """

    /// 종료 코드. CI 가 이걸로 판단한다.
    ///
    /// `Sendable` 을 직접 적는다. 모듈 밖에서는 public 타입에 이 적합성이 자동으로
    /// 붙지 않아서, `main.swift` 가 `run` 의 결과를 받는 자리에서 막힌다.
    public enum ExitCode: Int32, Sendable {
        case success = 0
        case failure = 1
        /// 명령을 잘못 썼다. 서버 문제와 구분해서 재시도할 가치가 없음을 알린다.
        case usage = 2
    }

    /// 명령 하나를 실행하고 종료 코드를 돌려준다.
    public static func run(
        arguments raw: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: @escaping @Sendable (String) -> Void = { say($0) },
        complain: @escaping @Sendable (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) async -> ExitCode {
        guard let command = raw.first else {
            complain(usage)
            return .usage
        }
        let rest = Array(raw.dropFirst())

        do {
            switch command {
            case "version":
                output("alley \(version) (API v\(APIPath.currentAPIVersion))")
                return .success

            case "help", "--help", "-h":
                output(usage)
                return .success

            case "upload":
                let options = try parseUpload(rest)
                let api = StoreAPI(config: try CLIConfig.load(from: environment))
                try await UploadCommand(api: api, log: output).run(options)
                return .success

            case "versions":
                let api = StoreAPI(config: try CLIConfig.load(from: environment))
                let app = try await api.currentApp()
                for version in try await api.versions(ofApp: app.id).sorted(by: {
                    $0.buildNumber > $1.buildNumber
                }) {
                    output(
                        "\(version.shortVersion) (\(version.buildNumber))\t\(version.state.displayName)"
                    )
                }
                return .success

            case "auth":
                return try await runAuth(
                    arguments: rest,
                    environment: environment,
                    output: output,
                    complain: complain
                )

            case "mcp":
                // **표준 출력은 규약이 쓴다.** 여기서 한 줄이라도 찍으면 붙어 있던
                // 에이전트가 그 줄을 파싱하려다 끊는다.
                let config = try CLIConfig.load(from: environment)
                // 배포 토큰으로도 서버는 뜬다. 그러면 도구 일곱 개가 목록에 나오고
                // 부를 때마다 인증 실패가 돌아온다. 에이전트 안에서 그 이유를
                // 알아내는 것보다 여기서 한 줄로 말하는 편이 낫다.
                guard config.token.hasPrefix(UserTokenPrefix.person) else {
                    complain(
                        """
                        mcp 는 사람 토큰이 필요합니다. 웹 콘솔의 내 설정 > 내 토큰에서 \
                        발급한 값(\(UserTokenPrefix.person)…)을 ALLEY_TOKEN 에 넣으세요. \
                        배포 토큰으로는 업로드밖에 되지 않습니다.
                        """
                    )
                    return .usage
                }
                await MCPServer(api: StoreAPI(config: config), complain: complain).run()
                return .success

            case "whoami":
                let api = StoreAPI(config: try CLIConfig.load(from: environment))
                let app = try await api.currentApp()
                output("\(app.name) (\(app.bundleID))")
                return .success

            default:
                complain("모르는 명령입니다: \(command)\n\n\(usage)")
                return .usage
            }
        } catch let parseError as Arguments.ParseError {
            complain("\(parseError)\n\n\(usage)")
            return .usage
        } catch let usageError as UsageError {
            complain("\(usageError)\n\n\(usage)")
            return .usage
        } catch let configError as CLIConfig.ConfigError {
            complain("\(configError)")
            return .usage
        } catch {
            // 서버 오류와 업로드 실패가 여기로 온다. 설정 실수와 달리 재시도할
            // 가치가 있어서 종료 코드를 나눈다.
            complain(describe(error))
            return .failure
        }
    }

    /// 명령을 잘못 쓴 경우.
    public struct UsageError: Error, CustomStringConvertible {
        public var description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    static func parseUpload(_ raw: [String]) throws -> UploadCommand.Options {
        let arguments = try Arguments(
            raw,
            valueOptions: ["version", "build", "app", "notes", "min-os", "entitlements"],
            flagOptions: ["signed", "release"]
        )

        guard let file = arguments.positional.first else {
            throw UsageError("올릴 파일을 지정하세요. 예: alley upload build/MyApp.zip --version 1.2.0")
        }
        guard arguments.positional.count == 1 else {
            throw UsageError("파일은 하나만 올릴 수 있습니다: \(arguments.positional.joined(separator: ", "))")
        }
        guard let shortVersion = arguments.string("version"), !shortVersion.isEmpty else {
            throw UsageError("--version 이 필요합니다. 예: --version 1.2.0")
        }

        return UploadCommand.Options(
            file: URL(fileURLWithPath: file),
            shortVersion: shortVersion,
            buildNumber: try arguments.integer("build"),
            releaseNotes: arguments.string("notes"),
            minimumOSVersion: arguments.string("min-os"),
            // 서버가 무시한다. 워커가 번들을 열어보고 판정한다 (ADR-0035).
            // 옛 스크립트가 `--signed` 를 계속 넘겨도 깨지지 않게 받아만 둔다.
            uploadKind: nil,
            entitlements: try readEntitlements(at: arguments.string("entitlements")),
            releaseAfterUpload: arguments.flag("release"),
            expectedBundleID: arguments.string("app")
        )
    }

    /// `--entitlements` 가 가리키는 파일을 읽어 XML 원문으로 돌려준다.
    ///
    /// **여기서 형식까지 본다.** 파일이 없거나 plist 가 아닌 것은 서버 문제가 아니라 인자
    /// 실수라, 요청을 보내기 전에 종료 코드 2 로 끝낸다. 파이프라인이 그 차이로
    /// 재시도할지를 판단한다.
    static func readEntitlements(at path: String?) throws -> String? {
        guard let path else { return nil }

        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            throw UsageError(
                """
                --entitlements 가 가리키는 파일을 읽지 못했습니다: \(path)
                \(EntitlementsGuidance.whereToFind)
                """
            )
        }
        guard let xml = String(data: data, encoding: .utf8) else {
            throw UsageError(
                "--entitlements 파일이 UTF-8 텍스트가 아닙니다: \(path). XML plist 여야 합니다."
            )
        }

        do {
            try EntitlementsPlist.validate(xml)
        } catch let error as EntitlementsPlist.PlistError {
            throw UsageError("\(path): \(error)")
        }
        return xml
    }
}

// MARK: - 기기 연결 (ADR-0064)

extension CLI {
    static func runAuth(
        arguments: [String],
        environment: [String: String],
        output: (String) -> Void,
        complain: (String) -> Void
    ) async throws -> ExitCode {
        let location = Credentials.defaultLocation(environment: environment)
        let saved = (try? Credentials.load(from: location)) ?? Credentials()

        switch arguments.first {
        case "login":
            let explicit = value(of: "--server", in: arguments)
            let rawServer = explicit
                ?? environment["ALLEY_SERVER_URL"].flatMap { $0.isEmpty ? nil : $0 }
                ?? saved.onlyServer?.server
            guard let rawServer, let server = CLIConfig.normalize(serverAddress: rawServer) else {
                complain(AuthCommand.Failure.noServer.description)
                return .usage
            }

            let entry = try await AuthCommand.login(
                server: server, credentialsAt: location, report: output
            )
            output("연결됐습니다. \(entry.name ?? "이 기기") 로 \(server.absoluteString) 에 붙습니다.")
            output("저장한 곳: \(location.path)")
            return .success

        case "status":
            guard !saved.entries.isEmpty else {
                output("아직 붙여둔 스토어가 없습니다. `alley auth login` 으로 연결하세요.")
                return .success
            }
            for server in saved.entries.keys.sorted() {
                guard let entry = saved[server] else { continue }
                var line = "\(server)  \(entry.name ?? "이름 없음")"
                if let expiresAt = entry.expiresAt {
                    let days = Int(expiresAt.timeIntervalSinceNow / 86_400)
                    line += days >= 0 ? "  (\(days)일 남음)" : "  (만료됨)"
                }
                output(line)
            }
            return .success

        case "logout":
            let target = value(of: "--server", in: arguments)
                ?? environment["ALLEY_SERVER_URL"]
                ?? saved.onlyServer?.server
            guard let target, let server = CLIConfig.normalize(serverAddress: target) else {
                complain(AuthCommand.Failure.noServer.description)
                return .usage
            }
            var updated = saved
            guard updated[server.absoluteString] != nil else {
                output("\(server.absoluteString) 에 붙여둔 것이 없습니다.")
                return .success
            }
            updated[server.absoluteString] = nil
            try updated.save(to: location)
            // **서버 쪽 토큰은 살아 있다.** 이 파일에서 지웠을 뿐이다. 남의 손에
            // 넘어갔을까 걱정된다면 내 토큰 화면에서 폐기해야 한다.
            output("지웠습니다. 서버에 남은 토큰은 내 설정 > 내 토큰에서 폐기하세요.")
            return .success

        default:
            complain("auth 는 login, status, logout 중 하나입니다.\n\n\(usage)")
            return .usage
        }
    }

    /// `--이름 값` 에서 값을 꺼낸다.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

// MARK: - 표준 출력

extension CLI {
    /// 한 줄을 표준 출력으로 내보내고 바로 흘려보낸다.
    ///
    /// **`print` 만 쓰지 않는다.** 표준 출력이 파이프면 libc 가 블록 단위로 모았다가
    /// 내보내고, 그 버퍼는 프로세스가 끝날 때까지 비지 않는다. `auth login` 은 사람이
    /// 브라우저에서 누르기를 기다리는 동안 주소를 먼저 보여줘야 하는데, 기다리는
    /// 사이에는 프로세스가 끝나지 않아 아무것도 안 보인다. `mcp` 도 같은 이유로
    /// `FileHandle` 에 직접 쓴다.
    public static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

// MARK: - 오류 출력

extension CLI {
    /// 오류를 사람이 읽는 한 줄로.
    ///
    /// 우리가 던지는 오류는 전부 설명을 갖고 있다. 그렇지 않은 것(네트워크 오류 등)은
    /// 시스템 설명을 쓴다. `Error` 는 무엇이든 `description` 을 갖고 있어서 타입으로
    /// 가려낼 수 없으므로, 우리 것인지 이름으로 판단하지 않고 둘 다 시도한다.
    static func describe(_ error: any Error) -> String {
        let described = String(describing: error)
        // 설명을 붙이지 않은 오류는 타입 이름만 나온다. 그때는 시스템 설명이 낫다.
        return described.contains(" ") ? described : error.localizedDescription
    }
}
