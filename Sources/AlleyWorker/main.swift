import AlleyShared
import AlleyWorkerCore
import Foundation

/// 서명 워커 진입점.
///
/// 실제 동작은 `AlleyWorkerCore` 에 있다. 여기서는 명령을 고르고 설정을 읽는다.
enum Command: String {
    case preflight
    case run
    case version

    static let usage = """
        사용법: alley-worker <command>

        명령:
          preflight   이 머신이 서명·공증을 수행할 준비가 됐는지 점검한다
          run         잡을 기다렸다 처리하는 것을 반복한다 (launchd 가 부르는 명령)
          version     워커 버전을 출력한다

        필수 환경변수:
          ALLEY_SERVER_URL        잡을 받아올 서버 주소
          ALLEY_WORKER_TOKEN      워커 인증 토큰 (웹 콘솔에서 발급)
          ALLEY_SIGNING_IDENTITY  키체인의 Developer ID Application identity 이름
          ALLEY_NOTARY_PROFILE    notarytool store-credentials 로 저장한 프로필 이름

        선택 환경변수:
          ALLEY_WORKER_NAME       웹 콘솔에 표시할 이름 (기본값: 호스트 이름)
          ALLEY_WORK_DIR          작업 디렉터리 (기본값: 임시 디렉터리 하위)
          ALLEY_POLL_TIMEOUT      long-poll 대기 시간(초) (기본값: 30)
        """
}

let workerVersion = "0.1.0"

/// 로그를 한 줄씩 즉시 내보낸다.
///
/// `launchd` 가 표준 출력을 파일로 받는다. 버퍼에 남아 있으면 무슨 일이 일어나는지
/// 실시간으로 볼 수 없고, 프로세스가 죽으면 그대로 사라진다.
func emit(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardOutput.write(Data("[\(stamp)] \(message)\n".utf8))
}

func loadConfig() -> WorkerConfig {
    do {
        return try WorkerConfig.load()
    } catch {
        FileHandle.standardError.write(Data("설정을 읽지 못했습니다: \(error)\n".utf8))
        exit(1)
    }
}

let arguments = CommandLine.arguments.dropFirst()

guard let rawCommand = arguments.first else {
    FileHandle.standardError.write(Data((Command.usage + "\n").utf8))
    exit(2)
}

guard let command = Command(rawValue: rawCommand) else {
    FileHandle.standardError.write(Data("알 수 없는 명령: \(rawCommand)\n\n\(Command.usage)\n".utf8))
    exit(2)
}

switch command {
case .version:
    print("alley-worker \(workerVersion) (API v\(APIPath.currentAPIVersion))")

case .preflight:
    let config = loadConfig()

    print("워커 '\(config.name)' 환경 점검")
    print("서버: \(config.serverURL.absoluteString)")
    print("")

    let report = Preflight.run(config: config)
    for check in report.checks {
        print("\(check.passed ? "✓" : "✗") \(check.name)")
        print("    \(check.detail)")
    }
    print("")

    if report.allPassed {
        print("모든 점검을 통과했습니다.")
    } else {
        let failed = report.checks.filter { !$0.passed }.count
        FileHandle.standardError.write(Data("점검 \(failed)건이 실패했습니다.\n".utf8))
        exit(1)
    }

case .run:
    let config = loadConfig()

    // 환경이 망가진 채로 잡을 가져가면, 잡 하나를 실패로 만들고 나서야 알게 된다.
    // 시작할 때 한 번 점검하고 안 되면 아예 뜨지 않는다. launchd 가 다시 띄우면서
    // 로그에 같은 이유가 반복되므로, 무엇이 문제인지 찾기도 쉽다.
    let report = Preflight.run(config: config)
    guard report.allPassed else {
        for check in report.checks where !check.passed {
            FileHandle.standardError.write(Data("✗ \(check.name): \(check.detail)\n".utf8))
        }
        FileHandle.standardError.write(Data("환경 점검에 실패해 시작하지 않습니다.\n".utf8))
        exit(1)
    }

    await WorkerLoop(config: config, log: emit).run()
}
