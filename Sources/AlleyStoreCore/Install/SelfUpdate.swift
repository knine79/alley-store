import AlleyProcess
import AppKit
import Foundation

/// 스토어 앱이 자기 자신을 갈아끼운다.
///
/// **실행 중인 자기를 덮어쓸 수는 없다.** 파일을 바꾸는 순간 지금 도는 프로세스의
/// 코드 서명이 깨지고, macOS 가 그 프로세스를 죽인다. 그래서 교체는 앱이 종료된 뒤에
/// 일어나야 하고, 그 일을 할 누군가가 앱 밖에 있어야 한다.
///
/// 작은 셸 스크립트를 띄워두고 앱이 스스로 종료한다. 스크립트는 프로세스가 사라지길
/// 기다렸다가 번들을 바꾸고 다시 띄운다. Sparkle 이 하는 일과 같은 순서인데, 우리는
/// 이미 받아둔 파일과 검증을 그대로 쓴다.
///
/// 스토어 앱은 Sparkle 을 쓰지 않는다. 다른 앱들이 쓸 appcast 는 서버가 내주지만
/// (ADR-0017), 스토어 앱 자신은 이미 스토어에서 앱을 받아 설치하는 코드를 갖고 있어서
/// 프레임워크를 하나 더 얹을 이유가 없다.
enum SelfUpdate {
    enum SelfUpdateError: LocalizedError {
        case notInBundle
        case notReplaceable(Blocker)
        case cannotWriteScript(String)

        var errorDescription: String? {
            switch self {
            case .notInBundle:
                return """
                    앱 번들 밖에서 실행 중이라 자기 자신을 업데이트할 수 없습니다. \
                    개발 중에는 정상입니다.
                    """
            case .notReplaceable(let blocker):
                return blocker.message
            case .cannotWriteScript(let detail):
                return "업데이트 준비에 실패했습니다.\n\(detail)"
            }
        }
    }

    /// 제자리에서 갈아끼울 수 없는 까닭. 사람이 할 일이 달라서 나눈다.
    enum Blocker: Equatable {
        /// 읽기 전용 볼륨에서 떴다. App Translocation 과 dmg 가 그렇다. 옮기면 풀린다.
        case readOnlyLocation
        /// 쓸 권한이 없다. MDM 이나 pkg 로 깔려 root 가 가진 번들이 대표적이고, 그
        /// 사람에게 "응용 프로그램 폴더로 옮기라" 고 하면 이미 거기 있는 앱을 두고 따를
        /// 수 없는 말이 된다. 다른 계정이 만든 공유 폴더에서 연 경우처럼 옮기면 풀리는
        /// 때도 섞여 있어서, 할 수 있는 두 가지를 함께 적는다.
        case noPermission

        /// 배너와 오류가 같은 말을 하게 한 자리에 둔다.
        var message: String {
            switch self {
            case .readOnlyLocation:
                return "이 자리에서는 스스로 업데이트할 수 없습니다. 응용 프로그램 폴더로 옮긴 뒤 다시 열어주세요."
            case .noPermission:
                return "이 앱을 바꿀 권한이 없어 스스로 업데이트할 수 없습니다. 내 응용 프로그램 폴더(~/Applications)로 옮기거나 관리자에게 알려주세요."
            }
        }
    }

    /// 지금 도는 앱의 번들 위치.
    ///
    /// `swift run` 으로 띄운 맨 실행 파일에는 번들이 없다. 그때는 nil 이다.
    static func currentBundle() -> URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// 이 자리의 번들을 갈아끼울 수 있나.
    ///
    /// **못 바꾸는 자리에서 뜬 앱이 흔하다.** 격리 속성이 남은 채 연 앱은 macOS 가
    /// 읽기 전용 사본(App Translocation)에서 띄우고, dmg 안에서 바로 연 앱도 읽기
    /// 전용이다. 그 상태로 교체를 시도하면 스크립트가 지우지도 놓지도 못한 채 옛
    /// 번들을 다시 띄운다. 앱은 여전히 새 버전이 있다고 보므로 다음 차례에 또 종료하고,
    /// 사용자에게는 앱이 이유 없이 꺼졌다 켜지는 것으로만 보인다.
    ///
    /// 경로 이름으로 가리지 않는다. Translocation 경로의 모양은 문서화된 것이
    /// 아니다. 볼륨이 읽기 전용인지를 먼저 보고, 아니면 실제로 쓸 수 있는지를 본다.
    /// 스크립트가 하는 일이 번들을 지우고 부모 폴더에 새로 놓는 것이라 둘 다 본다.
    ///
    /// 갈아끼울 수 있으면 nil 이다.
    static func blocker(for bundle: URL, fileManager: FileManager = .default) -> Blocker? {
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly ?? false
        if readOnly { return .readOnlyLocation }

        let writable = fileManager.isWritableFile(atPath: bundle.path)
            && fileManager.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        return writable ? nil : .noPermission
    }

    /// 교체를 맡길 스크립트.
    ///
    /// 경로에 공백이 흔하다(`Alley Store.app`). 전부 따옴표로 감싼다.
    /// `ditto` 를 쓰는 이유는 `.app` 안의 심볼릭 링크와 확장 속성을 그대로 옮기기
    /// 위해서다. `cp -r` 은 그것을 망가뜨려 서명을 깬다.
    static func script(pid: Int32, replacement: URL, destination: URL) -> String {
        """
        #!/bin/bash
        # 스토어 앱이 스스로 만든 교체 스크립트다. 앱이 종료되면 번들을 바꾸고 다시 띄운다.
        set -u

        # 앱이 실제로 사라질 때까지 기다린다. 저장 확인 창이 뜨는 경우가 있어 넉넉히 준다.
        for _ in $(seq 1 100); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.2
        done

        # 그래도 살아 있으면 건드리지 않는다. 도는 앱을 덮어쓰면 그 앱이 이상하게 죽는다.
        if kill -0 \(pid) 2>/dev/null; then
            exit 1
        fi

        BACKUP="$(mktemp -d)/backup.app"
        if ! /usr/bin/ditto "\(destination.path)" "$BACKUP"; then
            exit 1
        fi

        /bin/rm -rf "\(destination.path)"
        if /usr/bin/ditto "\(replacement.path)" "\(destination.path)"; then
            /bin/rm -rf "$BACKUP"
        else
            # 새 것을 못 놓았으면 있던 것을 되돌린다. 앱이 사라진 채로 끝나면 안 된다.
            /usr/bin/ditto "$BACKUP" "\(destination.path)"
        fi

        /usr/bin/open "\(destination.path)"
        """
    }

    /// 교체 스크립트를 띄우고 앱을 종료한다.
    ///
    /// 이 함수가 돌아오면 앱은 곧 사라진다. 부르는 쪽에서 뒤에 할 일을 두면 안 된다.
    ///
    /// 마지막에 `NSApplication` 을 건드리므로 메인 액터에 묶는다. 부르는 쪽
    /// (`StoreModel`)도 메인 액터라 경계를 넘지 않는다.
    @MainActor
    static func replaceAndRelaunch(with replacement: URL) throws {
        guard let destination = currentBundle() else {
            throw SelfUpdateError.notInBundle
        }
        // 부르는 쪽이 먼저 거르지만 여기서도 막는다. 여기를 지나면 앱이 종료된다.
        if let blocker = blocker(for: destination) {
            throw SelfUpdateError.notReplaceable(blocker)
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-self-update-\(UUID().uuidString).sh")
        let body = script(
            pid: ProcessInfo.processInfo.processIdentifier,
            replacement: replacement,
            destination: destination
        )

        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw SelfUpdateError.cannotWriteScript(error.localizedDescription)
        }

        // 앱이 죽어도 살아남아야 한다. 자식으로 두면 함께 사라진다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try? process.run()

        NSApplication.shared.terminate(nil)
    }
}
