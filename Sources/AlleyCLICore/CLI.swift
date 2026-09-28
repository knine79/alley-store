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
          upload <파일.zip>   새 버전을 올린다
          versions            이 앱의 버전 목록을 본다
          whoami              이 토큰이 어느 앱의 것인지 본다
          mcp                 코딩 에이전트에게 스토어를 내준다 (MCP, stdio)
          version             alley 버전을 출력한다

        mcp 는 사람 토큰(alleyu_)으로 붙습니다. 내 설정 > 내 토큰에서 발급하고
        ALLEY_TOKEN 에 넣으세요. 배포 토큰으로는 업로드밖에 되지 않습니다.

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

        환경변수:
          ALLEY_SERVER_URL    스토어 서버 주소
          ALLEY_TOKEN         앱 상세 화면에서 발급한 배포 토큰

        예시:
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
        output: @escaping @Sendable (String) -> Void = { print($0) },
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
