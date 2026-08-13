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
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let waiter = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                waiter.signal()
            }
            if waiter.wait(timeout: deadline) == .timedOut {
                timedOut = true
                process.terminate()
                // terminate 후에도 파이프가 닫힐 때까지 기다린다.
                process.waitUntilExit()
            }
        } else {
            process.waitUntilExit()
        }

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
