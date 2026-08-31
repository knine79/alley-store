import AlleyShared
import Vapor

/// 오류를 API 에는 JSON 으로, 브라우저에는 사람이 읽을 화면으로 돌려준다.
///
/// Vapor 기본 `ErrorMiddleware` 는 언제나 JSON 을 준다. 웹 콘솔에서 실수로 주소를
/// 잘못 치면 사용자가 `{"error":true,...}` 를 보게 된다.
///
/// 판단은 **경로**로만 한다. `Accept` 헤더로 고르면 같은 주소가 부르는 쪽에 따라
/// 다르게 응답해서, 문제가 생겼을 때 무엇을 보고 있는지 헷갈린다.
public struct ConsoleErrorMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            return await handle(error, for: request)
        }
    }

    /// 기계가 부르는 경로인지.
    ///
    /// 스토어 앱과 워커와 CLI 가 쓰는 곳이다. 여기서 HTML 을 주면 디코딩이 깨진다.
    private func servesJSON(_ request: Request) -> Bool {
        let path = request.url.path
        return path.hasPrefix(APIPath.apiRoot) || path == APIPath.health
    }

    private func handle(_ error: any Error, for request: Request) async -> Response {
        let status: HTTPStatus
        let reason: String
        let headers: HTTPHeaders

        switch error {
        case let abort as any AbortError:
            status = abort.status
            reason = abort.reason
            headers = abort.headers
        default:
            status = .internalServerError
            // 내부 오류의 자세한 내용은 로그에만 남긴다. 밖으로 나가면 구조가 드러난다.
            reason = "서버에서 문제가 발생했습니다."
            headers = [:]
        }

        if status == .internalServerError {
            request.logger.report(error: error)
        } else {
            request.logger.debug("요청 실패: \(status.code) \(reason)")
        }

        if servesJSON(request) {
            return jsonResponse(status: status, reason: reason, headers: headers, on: request)
        }

        // 브라우저에서 세션이 끊기면 오류 화면 대신 로그인으로 보낸다.
        // "인증되지 않았습니다"를 읽고 나서 스스로 로그인 주소를 찾아가게 할 이유가 없다.
        if status == .unauthorized {
            return request.redirect(to: "/")
        }

        return await htmlResponse(status: status, reason: reason, headers: headers, on: request)
    }

    private func jsonResponse(
        status: HTTPStatus,
        reason: String,
        headers: HTTPHeaders,
        on request: Request
    ) -> Response {
        let response = Response(status: status, headers: headers)
        response.headers.contentType = .json
        do {
            let encoded = try JSONEncoder().encode(ErrorPayload(error: true, reason: reason))
            response.body = .init(data: encoded)
        } catch {
            // 오류 문장을 직렬화하다 실패할 일은 사실상 없지만, 그때도 형태는 지킨다.
            request.logger.warning("오류 응답 직렬화 실패: \(error)")
            response.body = .init(string: #"{"error":true,"reason":"서버에서 문제가 발생했습니다."}"#)
        }
        return response
    }

    private func htmlResponse(
        status: HTTPStatus,
        reason: String,
        headers: HTTPHeaders,
        on request: Request
    ) async -> Response {
        do {
            let view = try await request.view.render(
                "error",
                ErrorPageContext(
                    page: try await request.pageContext(title: "\(status.code)"),
                    statusCode: Int(status.code),
                    reason: reason
                )
            ).get()
            let response = Response(status: status, headers: headers)
            response.headers.contentType = .html
            response.body = .init(buffer: view.data)
            return response
        } catch {
            // 오류 화면을 그리다 또 실패하면(예: 데이터베이스가 죽은 경우)
            // 최소한 상태 코드와 문장은 전한다.
            request.logger.warning("오류 화면 렌더링 실패: \(error)")
            let response = Response(status: status, headers: headers)
            response.headers.contentType = .plainText
            response.body = .init(string: "\(status.code) \(reason)")
            return response
        }
    }
}

struct ErrorPayload: Codable {
    var error: Bool
    var reason: String
}

struct ErrorPageContext: Encodable {
    var page: PageContext
    var statusCode: Int
    var reason: String
}
