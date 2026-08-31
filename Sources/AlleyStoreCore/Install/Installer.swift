import AlleyProcess
import AppKit
import Foundation

/// 받은 zip 을 검사해서 제자리에 놓는다.
///
/// 샌드박스를 쓰지 않기로 한 것이 여기서 값을 한다(ADR-0007). `/Applications` 에
/// 직접 쓰고, 실행 중인 앱에 종료를 요청할 수 있다.
struct Installer {
    enum InstallError: LocalizedError {
        case notWritable(directory: URL)
        case extractionFailed(detail: String)
        case stillRunning(name: String)
        case replaceFailed(detail: String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let directory):
                return "\(directory.path) 에 쓸 수 없습니다."
            case .extractionFailed(let detail):
                return "압축을 풀지 못했습니다.\n\(detail)"
            case .stillRunning(let name):
                return "\(name) 이(가) 아직 실행 중입니다. 종료한 뒤 다시 시도하세요."
            case .replaceFailed(let detail):
                return "설치 위치에 옮기지 못했습니다.\n\(detail)"
            }
        }
    }

    /// 설치가 끝난 자리.
    struct Result {
        var location: URL
        var replacedExisting: Bool
    }

    /// 앱을 어디에 둘지 고른다.
    ///
    /// `/Applications` 가 우선이다. 모두가 쓰는 자리이고 Spotlight 도 그쪽을 먼저 본다.
    /// 관리자 권한이 없는 계정이면 홈 아래로 물러선다. 권한을 요구하며 멈추는 것보다
    /// 자기 계정에라도 설치되는 편이 낫다.
    static func destinationDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: shared.path) {
            return shared
        }

        let personal = home.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: personal.path) else {
            throw InstallError.notWritable(directory: personal)
        }
        return personal
    }

    /// 내려받은 zip 을 풀고, 검사하고, 제자리에 놓는다.
    ///
    /// - Parameters:
    ///   - archive: 내려받은 zip.
    ///   - expectedSHA256: 서버가 알려준 해시. 없으면 대조를 건너뛴다.
    ///   - existing: 이미 깔려 있는 같은 앱. 팀 비교와 교체에 쓴다.
    func install(
        archive: URL,
        expectedSHA256: String?,
        replacing existing: InstalledApp?
    ) async throws -> Result {
        // 1. 받은 파일이 서버가 말한 그 파일인지.
        try BundleVerifier.verifyHash(of: archive, expected: expectedSHA256)

        let workspace = archive.deletingLastPathComponent()
            .appendingPathComponent("extracted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let extraction = await Shell.runDetached(
            "/usr/bin/ditto",
            ["-x", "-k", archive.path, workspace.path],
            timeout: 600
        )
        guard extraction.succeeded else {
            throw InstallError.extractionFailed(detail: extraction.combinedOutput)
        }

        let bundle = try locateApp(in: workspace)

        // 2. 서명과 공증. Gatekeeper 가 보는 것과 같은 것을 우리가 먼저 본다.
        try await BundleVerifier.verifySignature(of: bundle)

        // 3. 이미 깔린 앱과 같은 팀인지. 같은 번들 ID 로 바꿔치기하는 경로를 끊는다.
        let incomingTeam = await BundleVerifier.teamIdentifier(of: bundle)
        var installedTeam: String?
        if let existing {
            installedTeam = await BundleVerifier.teamIdentifier(of: existing.location)
        }
        try BundleVerifier.verifyTeam(incoming: incomingTeam, installed: installedTeam)

        return try place(bundle, replacing: existing)
    }

    // MARK: - 자리 잡기

    private func locateApp(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.extractionFailed(detail: "압축 안에 .app 번들이 없습니다.")
        }
        return app
    }

    /// 최종 위치로 옮긴다.
    ///
    /// 실행 중인 앱을 덮어쓰면 그 앱이 이상하게 죽는다. 먼저 종료를 요청하고, 그래도
    /// 살아 있으면 설치를 멈춘다. 강제로 죽이지는 않는다. 저장하지 않은 작업이 있을 수 있다.
    private func place(_ bundle: URL, replacing existing: InstalledApp?) throws -> Result {
        let destination: URL
        if let existing {
            // 이미 있는 앱은 원래 자리를 지킨다. 사용자가 옮겨둔 곳이 있으면 그곳이다.
            destination = existing.location
            try quit(bundleID: existing.bundleID, name: bundle.lastPathComponent)
        } else {
            destination = try Self.destinationDirectory()
                .appendingPathComponent(bundle.lastPathComponent)
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                // 옮기고 나서 지운다. 먼저 지우면 실패했을 때 아무것도 남지 않는다.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: bundle)
            } else {
                try FileManager.default.moveItem(at: bundle, to: destination)
            }
        } catch {
            throw InstallError.replaceFailed(detail: error.localizedDescription)
        }

        return Result(location: destination, replacedExisting: existing != nil)
    }

    /// 실행 중이면 종료를 요청하고 잠시 기다린다.
    private func quit(bundleID: String, name: String) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return }

        for application in running {
            application.terminate()
        }

        // 종료에는 시간이 걸린다. 저장 확인 창이 뜨는 앱도 있다.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw InstallError.stillRunning(name: name)
    }
}
