import Foundation

/// presigned URL 에서 파일을 받는다.
///
/// 서버를 거치지 않는다(ADR-0009). URL 자체가 자격증명이라 인증 헤더를 붙이지 않는다.
final class Downloader: NSObject, Sendable {
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

    /// 파일을 받아 디스크에 놓고 그 위치를 준다.
    ///
    /// 진행률은 `onProgress` 로 알린다. 사내 앱은 수백 MB 짜리도 있어서, 아무 표시가
    /// 없으면 멈춘 것처럼 보인다.
    func download(
        from url: URL,
        expectedSize: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (stream, response) = try await URLSession.shared.bytes(from: url)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.failed(status: status)
        }

        let total = expectedSize ?? (
            http.expectedContentLength > 0 ? http.expectedContentLength : nil
        )
        let destination = try Self.workspace()
            .appendingPathComponent("\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var written: Int64 = 0

        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                report(written: written, total: total, to: onProgress)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        report(written: written, total: total, to: onProgress)

        return destination
    }

    /// 한 번에 디스크로 넘기는 크기.
    ///
    /// 바이트 스트림을 한 바이트씩 쓰면 시스템 호출이 파일 크기만큼 일어난다.
    private let chunkSize = 1024 * 256

    private func report(
        written: Int64,
        total: Int64?,
        to onProgress: @Sendable (Double) -> Void
    ) {
        guard let total, total > 0 else { return }
        onProgress(min(1, Double(written) / Double(total)))
    }

    enum DownloadError: LocalizedError {
        case failed(status: Int)

        var errorDescription: String? {
            switch self {
            case .failed(let status):
                return "파일을 받지 못했습니다. 스토리지가 \(status) 를 돌려줬습니다. 다시 시도해보세요."
            }
        }
    }
}
