import AlleyProcess
import Foundation

/// 워커 머신이 서명·공증을 수행할 준비가 됐는지 확인한다.
///
/// 잡을 받은 뒤에 환경 문제로 실패하면 원인 파악이 번거롭다.
/// 설치 직후 이 점검을 한 번 돌려서 미리 걸러낸다.
public enum Preflight {
    public struct Check: Sendable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    public struct Report: Sendable {
        public var checks: [Check]

        public var allPassed: Bool {
            checks.allSatisfy(\.passed)
        }
    }

    public static func run(config: WorkerConfig) -> Report {
        Report(checks: [
            checkCommandLineTools(),
            checkNotaryTool(),
            checkSigningIdentity(config.signingIdentity),
            checkNotaryProfile(config.notaryProfile),
            checkWorkDirectory(config.workDirectory),
        ])
    }

    // MARK: - 개별 점검

    private static func checkCommandLineTools() -> Check {
        let result = Shell.run("/usr/bin/xcrun", ["--find", "codesign"])
        return Check(
            name: "codesign 사용 가능",
            passed: result.exitCode == 0,
            detail: result.exitCode == 0
                ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Xcode Command Line Tools를 설치하세요: xcode-select --install"
        )
    }

    private static func checkNotaryTool() -> Check {
        let result = Shell.run("/usr/bin/xcrun", ["--find", "notarytool"])
        return Check(
            name: "notarytool 사용 가능",
            passed: result.exitCode == 0,
            detail: result.exitCode == 0
                ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                : "notarytool을 찾지 못했습니다. Xcode 13 이상이 필요합니다."
        )
    }

    private static func checkSigningIdentity(_ identity: String) -> Check {
        // 키체인에서 유효한 코드 서명 identity 목록을 뽑아 설정값이 있는지 본다.
        let result = Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        let found = result.standardOutput.contains(identity)
        return Check(
            name: "서명 identity 존재",
            passed: found,
            detail: found
                ? "'\(identity)' 를 키체인에서 찾았습니다."
                : "'\(identity)' 를 키체인에서 찾지 못했습니다. security find-identity -v -p codesigning 으로 정확한 이름을 확인하세요."
        )
    }

    private static func checkNotaryProfile(_ profile: String) -> Check {
        // 프로필 자체를 조회하는 공식 명령이 없어서, 히스토리 조회로 자격증명이
        // 실제로 통하는지 확인한다. 인증에 실패하면 0이 아닌 코드가 돌아온다.
        let result = Shell.run(
            "/usr/bin/xcrun",
            ["notarytool", "history", "--keychain-profile", profile],
            timeout: 60
        )
        return Check(
            name: "공증 자격증명 유효",
            passed: result.exitCode == 0,
            detail: result.exitCode == 0
                ? "'\(profile)' 프로필로 App Store Connect 인증에 성공했습니다."
                : "'\(profile)' 프로필로 인증하지 못했습니다. xcrun notarytool store-credentials 로 먼저 저장하세요."
        )
    }

    private static func checkWorkDirectory(_ directory: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 실제로 쓸 수 있는지까지 확인한다. 권한 문제는 생성 시점에 안 드러날 수 있다.
            let probe = directory.appendingPathComponent(".alley-write-probe")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return Check(name: "작업 디렉터리 쓰기 가능", passed: true, detail: directory.path)
        } catch {
            return Check(
                name: "작업 디렉터리 쓰기 가능",
                passed: false,
                detail: "\(directory.path) 에 쓸 수 없습니다: \(error.localizedDescription)"
            )
        }
    }
}
