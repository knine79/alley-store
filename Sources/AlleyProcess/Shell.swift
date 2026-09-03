import Foundation

/// 외부 명령 실행 도우미.
///
/// 워커는 codesign, notarytool, stapler 를 호출해야 하므로 프로세스 실행이 핵심 경로다.
/// 출력을 파이프로 받을 때 버퍼가 차면 교착에 빠지므로 읽기를 병행한다.
public enum Shell {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var standardOutput: String
        public var standardError: String

        public var succeeded: Bool { exitCode == 0 }

        /// 실패 원인을 사람이 읽을 형태로 합친다.
        public var combinedOutput: String {
            [standardOutput, standardError]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// 명령을 동기 실행한다.
    ///
    /// - Parameter timeout: 초 단위 상한. 넘기면 프로세스를 종료하고 124를 돌려준다.
    ///                      공증 대기처럼 오래 걸리는 명령이 워커를 영구히 막지 않게 한다.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 종료를 `waitUntilExit()` 로 기다리지 않는다. 자식이 아주 빨리 끝나면 그
        // 호출이 종료를 놓치고 영영 돌아오지 않는다. 실제로 300KB 를 올리는 `curl`
        // 에서 이 일이 났다. 워커가 잡 하나를 물고 멈춰서 그 뒤로 아무 잡도 받지
        // 못했다. 몇 초씩 걸리는 codesign·notarytool 에서는 안 나던 것이다.
        //
        // `terminationHandler` 는 `run()` 전에 걸어두면 그 경합이 없다.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return Result(
                exitCode: 127,
                standardOutput: "",
                standardError: "\(executable) 를 실행하지 못했습니다: \(error.localizedDescription)"
            )
        }

        // 파이프 버퍼가 가득 차 자식 프로세스가 멈추지 않도록
        // 종료를 기다리는 동안 별도 스레드에서 계속 읽어낸다.
        let collector = OutputCollector()
        let readQueue = DispatchQueue(label: "alley.shell.read", attributes: .concurrent)
        let group = DispatchGroup()

        for (pipe, isStandardOutput) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            readQueue.async {
                defer { group.leave() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collector.append(data, isStandardOutput: isStandardOutput)
            }
        }

        var timedOut = false
        let deadline = timeout.map { DispatchTime.now() + $0 } ?? .distantFuture
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            // 죽이라고 했는데도 안 죽는 경우가 있다. 그때까지 붙잡혀 있지 않는다.
            _ = exited.wait(timeout: .now() + 10)
        }

        // 파이프가 닫혀야 읽기가 끝난다. 자식이 죽으면 닫힌다.
        group.wait()

        return Result(
            exitCode: timedOut ? 124 : process.terminationStatus,
            standardOutput: collector.standardOutput,
            standardError: timedOut
                ? collector.standardError + "\n명령이 \(Int(timeout ?? 0))초 안에 끝나지 않아 종료했습니다."
                : collector.standardError
        )
    }
}

extension Shell {
    /// 명령을 별도 스레드에서 돌리고 결과를 기다린다.
    ///
    /// `run` 은 스레드를 붙잡는다. 공증 대기처럼 몇 분씩 걸리는 명령을 async 함수에서
    /// 그대로 부르면 협력 스레드 풀 하나가 그동안 묶여서, 하트비트 같은 다른 작업이
    /// 함께 멈춘다.
    public static func runDetached(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: run(
                        executable,
                        arguments,
                        currentDirectory: currentDirectory,
                        timeout: timeout
                    )
                )
            }
        }
    }
}

/// 두 파이프에서 동시에 들어오는 출력을 안전하게 모은다.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func append(_ data: Data, isStandardOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStandardOutput {
            outData.append(data)
        } else {
            errData.append(data)
        }
    }

    var standardOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: outData, as: UTF8.self)
    }

    var standardError: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errData, as: UTF8.self)
    }
}
