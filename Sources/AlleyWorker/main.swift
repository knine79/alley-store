import AlleyShared
import Foundation

/// 서명 워커 진입점.
///
/// Phase 0 범위에서는 설정 로딩과 환경 점검(`preflight`)까지 제공한다.
/// 잡 폴링 루프는 서버의 워커 API가 준비되는 Phase 1-3에서 붙인다.
enum Command: String {
    case preflight
    case version

    static let usage = """
        사용법: alley-worker <command>

        명령:
          preflight   이 머신이 서명·공증을 수행할 준비가 됐는지 점검한다
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
    let config: WorkerConfig
    do {
        config = try WorkerConfig.load()
    } catch {
        FileHandle.standardError.write(Data("설정을 읽지 못했습니다: \(error)\n".utf8))
        exit(1)
    }

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
}
