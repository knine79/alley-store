import Foundation

/// presigned URL 에서 파일을 받는다.
///
/// 서버를 거치지 않는다(ADR-0009). URL 자체가 자격증명이라 인증 헤더를 붙이지 않는다.
///
/// `URLSessionDownloadTask` 를 쓴다. `URLSession.bytes` 는 한 바이트씩 넘겨주는
/// 시퀀스라, 수백 MB 를 받으면 바이트 수만큼 비동기 반복이 돌아 전송보다 그 오버헤드가
/// 커진다. 다운로드 태스크는 시스템이 파일로 직접 받고 진행률만 알려준다.
final class Downloader: NSObject {
    /// 받은 파일이 놓일 자리.
    ///
    /// 시스템 임시 디렉터리를 그대로 쓰지 않고 하위에 우리 폴더를 만든다. 설치가
    /// 실패했을 때 무엇이 남았는지 사람이 알아볼 수 있어야 한다.
    static func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-store", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let progressHandler: @Sendable (Double) -> Void
    /// 델리게이트 호출은 세션이 만든 큐에서 온다. 이어주기를 건드리는 자리가
    /// 그 큐와 `start` 두 곳이라 자물쇠로 묶는다.
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<URL, any Error>?

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = onProgress
        super.init()
    }

    /// 파일을 받아 디스크에 놓고 그 위치를 준다.
    ///
    /// 진행률은 `onProgress` 로 알린다. 사내 앱은 수백 MB 짜리도 있어서, 아무 표시가
    /// 없으면 멈춘 것처럼 보인다.
    static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = Downloader(onProgress: onProgress)
        return try await downloader.start(url: url)
    }

    private func start(url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            session.downloadTask(with: url).resume()
        }
    }

    enum DownloadError: LocalizedError {
        case failed(status: Int)
        case cannotKeepFile(detail: String)

        var errorDescription: String? {
            switch self {
            case .failed(let status):
                return "파일을 받지 못했습니다. 스토리지가 \(status) 를 돌려줬습니다. 다시 시도해보세요."
            case .cannotKeepFile(let detail):
                return "받은 파일을 저장하지 못했습니다.\n\(detail)"
            }
        }
    }
}

extension Downloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(
            min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 이 함수가 돌아가면 시스템이 임시 파일을 지운다. 여기서 우리 자리로 옮긴다.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            finish(with: .failure(DownloadError.failed(status: http.statusCode)))
            return
        }

        do {
            let destination = try Self.workspace()
                .appendingPathComponent("\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: location, to: destination)
            finish(with: .success(destination))
        } catch {
            finish(with: .failure(DownloadError.cannotKeepFile(detail: error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // 성공은 위에서 이미 이어줬다. 여기서는 실패만 다룬다.
        guard let error else { return }
        finish(with: .failure(error))
    }

    /// 이어주기는 한 번만 한다.
    ///
    /// 실패 경로가 둘(응답 오류, 전송 오류)이라 두 번 불릴 수 있는데, 이어주기를
    /// 두 번 하면 프로세스가 죽는다.
    private func finish(with result: Result<URL, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(with: result)
    }
}
