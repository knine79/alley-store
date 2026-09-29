import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 브라우저가 돌려보내는 한 번의 요청만 받는 자리 (ADR-0064).
///
/// **127.0.0.1 만 연다.** 0.0.0.0 으로 열면 같은 망의 다른 기계가 콜백을 흉내 낼 수
/// 있다. 루프백이라도 이 기계의 다른 프로세스는 부를 수 있어서, 부르는 쪽이 보낸
/// `state` 를 돌아온 값과 대조한다.
///
/// **웹 서버를 들이지 않는다.** 필요한 것은 요청 한 줄에서 쿼리를 읽고 사람이 볼 수
/// 있는 답 한 장을 돌려주는 것뿐이다. CLI 에 HTTP 서버 의존성을 더할 일이 아니다.
final class LoopbackListener {
    /// 커널이 골라준 포트.
    let port: Int

    private let socketHandle: Int32

    init() throws {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw AuthCommand.Failure.cannotListen("소켓을 만들지 못했습니다.")
        }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // 0 을 주면 커널이 빈 포트를 고른다. 고정 포트를 쓰면 두 번째 로그인이 막힌다.
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw AuthCommand.Failure.cannotListen("127.0.0.1 에 자리를 잡지 못했습니다.")
        }
        guard listen(handle, 1) == 0 else {
            close(handle)
            throw AuthCommand.Failure.cannotListen("기다리지 못했습니다.")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else {
            close(handle)
            throw AuthCommand.Failure.cannotListen("포트를 알아내지 못했습니다.")
        }

        self.socketHandle = handle
        self.port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    struct Handback {
        var code: String
        var state: String
    }

    /// 한 번 받고 닫는다.
    ///
    /// `accept` 는 값이 올 때까지 돌아오지 않는다. 그대로 async 함수에서 부르면 협력
    /// 스레드 하나가 그동안 묶이므로 전용 스레드에서 기다린다 (`MCPServer.run` 이 같은
    /// 이유로 같은 일을 한다).
    func waitForCallback(limit: TimeInterval) async throws -> Handback {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { [socketHandle] in
                var timeout = timeval(
                    tv_sec: Int(limit),
                    tv_usec: 0
                )
                setsockopt(
                    socketHandle, SOL_SOCKET, SO_RCVTIMEO,
                    &timeout, socklen_t(MemoryLayout<timeval>.size)
                )

                let client = accept(socketHandle, nil, nil)
                guard client >= 0 else {
                    continuation.resume(throwing: AuthCommand.Failure.timedOut)
                    return
                }
                defer { close(client) }

                var buffer = [UInt8](repeating: 0, count: 4096)
                let read = recv(client, &buffer, buffer.count, 0)
                guard read > 0 else {
                    continuation.resume(throwing: AuthCommand.Failure.timedOut)
                    return
                }
                let request = String(decoding: buffer[0..<read], as: UTF8.self)

                guard let target = Self.requestTarget(request),
                      let components = URLComponents(string: "http://127.0.0.1\(target)"),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      let state = components.queryItems?.first(where: { $0.name == "state" })?.value
                else {
                    Self.reply(to: client, body: Self.failurePage)
                    continuation.resume(throwing: AuthCommand.Failure.timedOut)
                    return
                }

                Self.reply(to: client, body: Self.successPage)
                continuation.resume(returning: Handback(code: code, state: state))
            }
            thread.name = "alley-auth-callback"
            thread.start()
        }
    }

    func stop() {
        close(socketHandle)
    }

    /// `GET /?code=…&state=… HTTP/1.1` 에서 가운데를 꺼낸다.
    static func requestTarget(_ request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private static func reply(to client: Int32, body: String) {
        let payload = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        _ = payload.withCString { send(client, $0, strlen($0), 0) }
    }

    /// 브라우저에 남는 한 장. 여기서 끝났다는 것을 알려주고 창을 닫게 한다.
    private static let successPage = """
        <!DOCTYPE html><html lang="ko"><head><meta charset="utf-8"><title>연결됐습니다</title>
        <style>body{font-family:-apple-system,"Apple SD Gothic Neo",sans-serif;display:grid;
        place-items:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}
        p{color:#6e6e73;font-size:14px}</style></head>
        <body><div><h1>연결됐습니다</h1><p>이 창을 닫고 터미널로 돌아가세요.</p></div></body></html>
        """

    private static let failurePage = """
        <!DOCTYPE html><html lang="ko"><head><meta charset="utf-8"><title>연결하지 못했습니다</title>
        <style>body{font-family:-apple-system,"Apple SD Gothic Neo",sans-serif;display:grid;
        place-items:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}
        p{color:#6e6e73;font-size:14px}</style></head>
        <body><div><h1>연결하지 못했습니다</h1><p>터미널에서 다시 시도해 주세요.</p></div></body></html>
        """
}
