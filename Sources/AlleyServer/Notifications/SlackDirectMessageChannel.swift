import AlleyShared
import Foundation
import Vapor

/// 사람에게 Slack DM 을 보낸다.
///
/// **웹훅과 다른 물건이다.** `SlackWebhookChannel` 은 만들 때 정한 채널 하나에만 쓰고,
/// 받는 사람을 고를 수 없다. 서명 실패는 그 버전을 올린 사람이 고치는 일이라 그
/// 사람에게 닿아야 한다. 앱 채널에 뿌리면 남 일이 되고, 앱마다 채널을 파야 하는
/// 부담도 생긴다.
///
/// 그래서 봇 토큰으로 두 번 부른다. 이메일로 Slack 사용자를 찾고, 그 사용자에게
/// 글을 쓴다. Slack 앱에 `users:read.email` 과 `chat:write` 가 있어야 한다.
///
/// **이메일이 같은 사람이라고 가정한다.** 스토어의 계정 이메일과 Slack 계정 이메일이
/// 다르면 찾지 못하고, 그때는 보내지 않고 그 사실을 남긴다. 조직 계정으로 둘 다
/// 쓰는 것이 보통이라 이 가정으로 시작하고, 어긋나는 사람이 나오면 그때 이어주는
/// 칸을 만든다.
public struct SlackDirectMessageChannel: NotificationChannel, Sendable {
    public let kind: NotificationChannelKind = .slackDirectMessage

    private let client: any Client
    private let botToken: String

    public init(client: any Client, botToken: String) {
        self.client = client
        self.botToken = botToken
    }

    public enum ChannelError: Error, CustomStringConvertible {
        /// 그 이메일을 쓰는 Slack 사용자가 없다.
        case noSuchUser(email: String)
        /// Slack 이 거절했다. `error` 는 Slack 이 준 코드다.
        case rejected(api: String, error: String)
        case transport(String)

        public var description: String {
            switch self {
            case .noSuchUser(let email):
                return "'\(email)' 로 Slack 사용자를 찾지 못했습니다. 스토어 계정과 Slack 계정의 이메일이 다를 수 있습니다."
            case .rejected(let api, let error):
                return "Slack \(api) 가 거절했습니다: \(error)"
            case .transport(let detail):
                return "Slack 에 연결하지 못했습니다: \(detail)"
            }
        }
    }

    /// `endpoint` 는 받는 사람의 이메일이다.
    public func send(_ message: NotificationMessage, to endpoint: String) async throws {
        let userID = try await lookupUser(email: endpoint)
        try await post(message, to: userID)
    }

    // MARK: - Slack API

    private func lookupUser(email: String) async throws -> String {
        let response = try await call(
            "users.lookupByEmail",
            query: "email=\(email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email)"
        )
        let decoded = try response.content.decode(LookupResponse.self)
        guard decoded.ok, let id = decoded.user?.id else {
            // 이 오류만 따로 가른다. 나머지는 설정이나 권한 문제이고, 이것은 사람마다
            // 다른 일이라 받는 쪽이 할 수 있는 조치가 다르다.
            if decoded.error == "users_not_found" {
                throw ChannelError.noSuchUser(email: email)
            }
            throw ChannelError.rejected(api: "users.lookupByEmail", error: decoded.error ?? "알 수 없음")
        }
        return id
    }

    private func post(_ message: NotificationMessage, to userID: String) async throws {
        // Slack 은 mrkdwn 을 쓴다. HTML 도 마크다운도 아니라서 링크 형식이 독특하다.
        var text = "*\(message.title)*"
        if let body = message.body, !body.isEmpty {
            text += "\n\(body)"
        }
        if let link = message.link {
            text += "\n<\(link)|웹 콘솔에서 보기>"
        }

        // 사용자 ID 를 채널로 넘기면 그 사람과의 DM 으로 간다.
        let response = try await call("chat.postMessage", body: PostBody(channel: userID, text: text))
        let decoded = try response.content.decode(PostResponse.self)
        guard decoded.ok else {
            throw ChannelError.rejected(api: "chat.postMessage", error: decoded.error ?? "알 수 없음")
        }
    }

    /// **Slack 은 실패도 200 으로 준다.** 상태 코드만 보면 다 성공으로 읽힌다.
    /// 본문의 `ok` 를 부르는 쪽에서 확인한다.
    private func call(_ method: String, query: String) async throws -> ClientResponse {
        do {
            return try await client.get(URI(string: "https://slack.com/api/\(method)?\(query)")) {
                $0.headers.bearerAuthorization = .init(token: botToken)
            }
        } catch {
            throw ChannelError.transport(String(describing: error))
        }
    }

    private func call(_ method: String, body: some Content) async throws -> ClientResponse {
        do {
            return try await client.post(URI(string: "https://slack.com/api/\(method)")) { request in
                request.headers.bearerAuthorization = .init(token: botToken)
                request.headers.contentType = .json
                try request.content.encode(body)
            }
        } catch {
            throw ChannelError.transport(String(describing: error))
        }
    }

    private struct LookupResponse: Content {
        struct SlackUser: Content {
            var id: String
        }
        var ok: Bool
        var error: String?
        var user: SlackUser?
    }

    private struct PostBody: Content {
        var channel: String
        var text: String
    }

    private struct PostResponse: Content {
        var ok: Bool
        var error: String?
    }
}
