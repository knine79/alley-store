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
        case cannotWriteScript(String)

        var errorDescription: String? {
            switch self {
            case .notInBundle:
                return """
                    앱 번들 밖에서 실행 중이라 자기 자신을 업데이트할 수 없습니다. \
                    개발 중에는 정상입니다.
                    """
            case .cannotWriteScript(let detail):
                return "업데이트 준비에 실패했습니다.\n\(detail)"
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
    static func replaceAndRelaunch(with replacement: URL) throws {
        guard let destination = currentBundle() else {
            throw SelfUpdateError.notInBundle
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
