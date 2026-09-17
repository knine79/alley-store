import Foundation
import NIOConcurrencyHelpers
import Vapor

/// 종료가 시작됐다는 것을 오래 열려 있는 요청에 알린다.
///
/// 워커의 잡 폴링은 큐가 비어 있으면 응답을 쥔 채 최대 25초를 기다린다
/// (`WorkerController.nextJob`). 그 사이에 서버가 내려가면 Vapor 는 연결을 정리한 뒤
/// 데이터베이스를 닫는데, **핸들러는 그것과 상관없이 계속 돈다.** 다음 회전에서
/// `request.db` 를 다시 잡는 순간 프로세스가 죽는다. 그 프로퍼티는 강제 언래핑이라
/// (`FluentProvider.swift:24`) 닫힌 뒤에는 nil 을 돌려주고, Fluent 는 그것을 오류로
/// 만들어 주지 않는다.
///
/// 폴링 주기가 1초라 창이 넓다. 롤아웃마다 종료가 깨끗하지 않았던 이유다 (ADR-0052).
///
/// 그래서 종료를 폴링에 알려 스스로 빠져나가게 하고, 다 빠져나간 뒤에 데이터베이스를
/// 닫는다.
public final class ShutdownSignal: Sendable {
    private struct State {
        var isShuttingDown = false
        var openPolls = 0
    }

    private let state = NIOLockedValueBox(State())
    /// 신호원을 잡아둔다. 놓으면 취소되어 더 이상 신호를 받지 못한다.
    private let sources = NIOLockedValueBox<[DispatchSourceSignal]>([])

    public init() {}

    /// 종료가 시작됐는가.
    public var isShuttingDown: Bool {
        self.state.withLockedValue { $0.isShuttingDown }
    }

    /// 지금 열려 있는 긴 폴링 수.
    public var openPolls: Int {
        self.state.withLockedValue { $0.openPolls }
    }

    /// 종료가 시작됐다고 알린다. 여러 번 불러도 된다.
    public func begin() {
        self.state.withLockedValue { $0.isShuttingDown = true }
    }

    /// 긴 폴링 하나가 들어온다. 나갈 때 반드시 `leave()` 를 부른다.
    func enter() {
        self.state.withLockedValue { $0.openPolls += 1 }
    }

    func leave() {
        self.state.withLockedValue { $0.openPolls = max(0, $0.openPolls - 1) }
    }

    /// 열려 있는 폴링이 모두 빠져나갈 때까지 기다린다.
    ///
    /// 폴링은 1초에 한 번 깨어나므로 신호를 받은 뒤 대개 그 안에 끝난다. 그래도
    /// 돌아오지 않는 것이 있으면 이쪽이 종료를 붙잡는 셈이 되므로 상한을 둔다.
    /// 여기서 포기해도 최악은 고치기 전과 같다.
    public func waitForOpenPolls(
        timeout: Duration = .seconds(3),
        checkInterval: Duration = .milliseconds(50)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while self.openPolls > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: checkInterval)
        }
    }

    /// `SIGINT` 와 `SIGTERM` 을 직접 듣는다.
    ///
    /// Vapor 의 serve 명령도 같은 신호를 듣고 서버를 닫지만, 그 사실을 우리에게
    /// 알려주지 않는다. `DispatchSource` 는 한 신호에 여럿이 붙을 수 있어 서로를
    /// 가리지 않으므로 한 번 더 듣는다. **여기가 가장 이른 자리다.** 생애주기
    /// 훅까지 기다리면 그 전에 연결 정리가 끝나 있고, 그만큼 폴링이 오래 남는다.
    ///
    /// 프로세스 전역을 건드리므로 서버를 실제로 띄우는 자리에서만 부른다.
    public func listenForTermination() {
        let queue = DispatchQueue(label: "codes.alley.shutdown-signal")
        let made = [SIGINT, SIGTERM].map { code -> DispatchSourceSignal in
            // DispatchSource 로 듣기 전에 기본 동작(즉시 종료)을 끈다. serve 명령이
            // 하는 것과 같다.
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: queue)
            // 신호원을 우리가 들고 있으므로 핸들러까지 우리를 잡으면 서로를 놓지
            // 못한다. 이쪽은 애플리케이션이 살려두는 값이라 약하게 잡아도 된다.
            source.setEventHandler { [weak self] in self?.begin() }
            source.resume()
            return source
        }
        self.sources.withLockedValue { $0.append(contentsOf: made) }
    }
}

/// 데이터베이스가 닫히기 전에 긴 폴링을 먼저 내보낸다.
///
/// 신호를 못 들은 채로 종료하는 길도 있다. 테스트가 앱을 직접 내리거나, 오류를 만나
/// `asyncShutdown()` 으로 바로 들어오는 경우다. 그때는 이 훅이 마지막 방어선이 된다.
/// Vapor 는 생애주기 훅을 모두 부른 다음에야 저장소(그 안에 Fluent 가 있다)를 닫는다.
struct ShutdownSignalLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        let signal = application.shutdownSignal
        signal.begin()
        await signal.waitForOpenPolls()
    }
}

// MARK: - Vapor 연동

extension Application {
    private struct ShutdownSignalKey: StorageKey {
        typealias Value = ShutdownSignal
    }

    public var shutdownSignal: ShutdownSignal {
        if let existing = self.storage[ShutdownSignalKey.self] {
            return existing
        }
        let created = ShutdownSignal()
        self.storage[ShutdownSignalKey.self] = created
        return created
    }
}
