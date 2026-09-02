import Foundation
import Vapor

/// 주기마다 한 번씩 도는 뒷정리 작업.
///
/// **Vapor 에는 스케줄러가 없다.** Queues 패키지를 붙이면 Redis 같은 것이 따라오는데,
/// 하는 일이 "몇 분에 한 번 표를 훑는다"뿐이라 그 값을 하지 못한다. 애플리케이션
/// 수명에 묶인 Task 하나로 충분하다.
///
/// 같은 모양의 루프가 셋이 되어 여기로 모았다. 정책은 하나뿐이다. 뜨자마자 돌지
/// 않고 첫 주기를 기다린다. 기동 직후에는 워커가 아직 붙기 전이라, 그때 훑으면
/// 멀쩡한 것을 죽었다고 판단한다.
public final class PeriodicSweep: LifecycleHandler, @unchecked Sendable {
    private let name: String
    private let interval: Duration
    private let body: @Sendable (Application) async -> Void

    // Task 는 didBoot 에서 만들어 shutdown 에서 취소한다. LifecycleHandler 의
    // 메서드가 nonmutating 이라 값을 담을 자리에 자물쇠가 필요하다.
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(
        name: String,
        interval: Duration,
        body: @escaping @Sendable (Application) async -> Void
    ) {
        self.name = name
        self.interval = interval
        self.body = body
    }

    public func didBootAsync(_ application: Application) async throws {
        let interval = self.interval
        let body = self.body
        let name = self.name

        let task = Task {
            try? await Task.sleep(for: interval)
            while !Task.isCancelled {
                await body(application)
                try? await Task.sleep(for: interval)
            }
            application.logger.debug("주기 작업 '\(name)' 을 멈춥니다.")
        }

        store(task)
    }

    public func shutdownAsync(_ application: Application) async {
        take()?.cancel()
    }

    // NSLock 은 async 함수 안에서 직접 잠글 수 없다. 잠그는 구간을 동기 함수로 뺀다.
    private func store(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    private func take() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}
