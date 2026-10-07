import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

/// 스토어의 Slack 봇으로 채널에 글을 올린다 (ADR-0075).
///
/// **웹훅이 아니라 봇 토큰을 쓴다.** 웹훅으로 올린 글은 그 웹훅을 만든 Slack 앱의
/// 이름으로 보이는데, 앱 관리자가 스토어의 봇 앱에 웹훅을 만들 권한은 없다. 각자
/// 아무 앱으로 웹훅을 만들면 출시 소식이 제각각의 이름으로 올라가고, 채널에 글을 쓰는
/// 자격증명도 여기저기 흩어진다. 봇이면 언제나 스토어 이름으로 올라가고, 앱 관리자는
/// 채널에 봇을 초대하기만 하면 된다.
///
/// DM 에 쓰는 봇과 같은 토큰이다 (`SlackDirectMessageChannel`). 그쪽 권한에 더해
/// `channels:read`, `groups:read` 가 있어야 채널 이름으로 찾고 봇이 들어가 있는지 본다.
public struct SlackBot: Sendable {
    private let client: any Client
    private let token: String

    public init(client: any Client, token: String) {
        self.client = client
        self.token = token
    }

    /// 봇이 찾은 채널.
    public struct Channel: Sendable, Equatable {
        public var id: String
        /// `#` 없는 이름.
        public var name: String
        public var isMember: Bool
    }

    public enum BotError: Error, CustomStringConvertible, Equatable {
        /// 그 이름이나 ID 로 채널을 찾지 못했다.
        case noSuchChannel(String)
        /// 봇에 권한이 모자란다. `needed` 는 Slack 이 알려준 권한이다.
        case missingScope(needed: String?)
        /// Slack 이 거절했다. `error` 는 Slack 이 준 코드다.
        case rejected(api: String, error: String)
        case transport(String)

        public var description: String {
            switch self {
            case .noSuchChannel(let input):
                return "'\(input)' 채널을 찾지 못했습니다. 비공개 채널이면 봇을 먼저 초대해야 보입니다."
            case .missingScope(let needed):
                let scope = needed.map { " (\($0))" } ?? ""
                return "Slack 봇에 필요한 권한\(scope)이 없습니다. 스토어 관리자에게 권한 추가를 요청하세요."
            case .rejected(let api, let error):
                return "Slack \(api) 가 거절했습니다: \(error)"
            case .transport(let detail):
                return "Slack 에 연결하지 못했습니다: \(detail)"
            }
        }
    }

    // MARK: - 채널 찾기

    /// 사람이 적은 채널을 찾는다. `#이름`, `이름`, 채널 ID 를 모두 받는다.
    ///
    /// 이름으로 찾을 때는 목록을 끝까지 넘긴다. 큰 워크스페이스에는 채널이 수천 개다.
    public func findChannel(_ input: String) async throws -> Channel {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !name.isEmpty else { throw BotError.noSuchChannel(input) }

        if Self.looksLikeChannelID(name) {
            return try await channelInfo(id: name, input: input)
        }

        let target = name.lowercased()
        var cursor: String?
        repeat {
            var query = "types=public_channel,private_channel&exclude_archived=true&limit=1000"
            if let cursor, !cursor.isEmpty {
                query += "&cursor=\(Self.percentEncoded(cursor))"
            }
            let response = try await get("conversations.list", query: query)
            let page = try decode(ListResponse.self, from: response, api: "conversations.list")
            if let found = page.channels?.first(where: { $0.name.lowercased() == target }) {
                return Channel(id: found.id, name: found.name, isMember: found.isMember ?? false)
            }
            cursor = page.responseMetadata?.nextCursor
        } while cursor.map { !$0.isEmpty } ?? false

        throw BotError.noSuchChannel(input)
    }

    private func channelInfo(id: String, input: String) async throws -> Channel {
        let response = try await get("conversations.info", query: "channel=\(Self.percentEncoded(id))")
        guard let decoded = try? response.content.decode(InfoResponse.self) else {
            throw BotError.rejected(api: "conversations.info", error: "HTTP \(response.status.code)")
        }
        guard decoded.ok, let channel = decoded.channel else {
            if decoded.error == "channel_not_found" { throw BotError.noSuchChannel(input) }
            throw Self.failure(api: "conversations.info", error: decoded.error, needed: decoded.needed)
        }
        return Channel(id: channel.id, name: channel.name, isMember: channel.isMember ?? false)
    }

    /// Slack 채널 ID 모양인가. 공개는 `C`, 예전 비공개는 `G` 로 시작한다.
    static func looksLikeChannelID(_ text: String) -> Bool {
        guard let first = text.first, first == "C" || first == "G", text.count >= 9 else {
            return false
        }
        return text.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    // MARK: - 올리기

    /// 채널에 글을 올린다. `text` 는 알림 미리보기와 블록을 못 그리는 곳에 쓰인다.
    public func post(text: String, blocks: [SlackBlock], to channelID: String) async throws {
        let response: ClientResponse
        do {
            response = try await client.post(URI(string: "https://slack.com/api/chat.postMessage")) {
                $0.timeout = Self.timeout
                $0.headers.bearerAuthorization = .init(token: token)
                $0.headers.contentType = .json
                try $0.content.encode(PostBody(channel: channelID, text: text, blocks: blocks))
            }
        } catch {
            throw BotError.transport(String(describing: error))
        }
        _ = try decode(BasicResponse.self, from: response, api: "chat.postMessage")
    }

    /// 봇의 Slack 핸들. 화면의 `/invite @...` 안내에 쓴다.
    public func handle() async throws -> String {
        let decoded = try decode(
            AuthResponse.self, from: try await get("auth.test", query: ""), api: "auth.test"
        )
        guard let user = decoded.user, !user.isEmpty else {
            throw BotError.rejected(api: "auth.test", error: "봇 이름이 비어 있습니다")
        }
        return user
    }

    // MARK: - Slack API

    /// Slack 이 답하지 않을 때 기다리는 한도.
    ///
    /// 출시는 이미 저장된 뒤에 알리고, 앱 상세는 봇 이름을 묻는다. 둘 다 Slack 이
    /// 멈추면 함께 멈춘다. 기본 클라이언트에는 읽기 한도가 없다.
    static let timeout: TimeAmount = .seconds(5)

    /// **Slack 은 실패도 200 으로 준다.** 본문의 `ok` 를 본다.
    private func get(_ method: String, query: String) async throws -> ClientResponse {
        let suffix = query.isEmpty ? "" : "?\(query)"
        do {
            return try await client.get(URI(string: "https://slack.com/api/\(method)\(suffix)")) {
                $0.timeout = Self.timeout
                $0.headers.bearerAuthorization = .init(token: token)
            }
        } catch {
            throw BotError.transport(String(describing: error))
        }
    }

    private func decode<T: SlackResponse>(
        _ type: T.Type, from response: ClientResponse, api: String
    ) throws -> T {
        // Slack 앞단이 죽으면 JSON 이 아니라 HTML 이 온다. 그것도 Slack 오류로 돌려야
        // 화면이 오류 페이지가 아니라 제자리에서 이유를 말한다.
        let decoded: T
        do {
            decoded = try response.content.decode(T.self)
        } catch {
            throw BotError.rejected(api: api, error: "HTTP \(response.status.code)")
        }
        guard decoded.ok else {
            throw Self.failure(api: api, error: decoded.error, needed: decoded.needed)
        }
        return decoded
    }

    private static func failure(api: String, error: String?, needed: String?) -> BotError {
        if error == "missing_scope" { return .missingScope(needed: needed) }
        return .rejected(api: api, error: error ?? "알 수 없음")
    }

    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private struct PostBody: Content {
        var channel: String
        var text: String
        var blocks: [SlackBlock]
        /// 공유 링크를 펼치지 않는다. 사내망 스토어는 Slack 이 열지 못해 빈 상자만
        /// 남는다 (ADR-0072).
        var unfurlLinks = false
        var unfurlMedia = false

        enum CodingKeys: String, CodingKey {
            case channel, text, blocks
            case unfurlLinks = "unfurl_links"
            case unfurlMedia = "unfurl_media"
        }
    }

    private struct SlackChannelPayload: Codable {
        var id: String
        var name: String
        var isMember: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name
            case isMember = "is_member"
        }
    }

    private struct Metadata: Codable {
        var nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case nextCursor = "next_cursor"
        }
    }

    private struct ListResponse: SlackResponse {
        var ok: Bool
        var error: String?
        var needed: String?
        var channels: [SlackChannelPayload]?
        var responseMetadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case ok, error, needed, channels
            case responseMetadata = "response_metadata"
        }
    }

    private struct InfoResponse: SlackResponse {
        var ok: Bool
        var error: String?
        var needed: String?
        var channel: SlackChannelPayload?
    }

    private struct AuthResponse: SlackResponse {
        var ok: Bool
        var error: String?
        var needed: String?
        var user: String?
    }

    private struct BasicResponse: SlackResponse {
        var ok: Bool
        var error: String?
        var needed: String?
    }
}

private protocol SlackResponse: Content {
    var ok: Bool { get }
    var error: String? { get }
    var needed: String? { get }
}

/// Slack Block Kit 블록. 출시 소식이 쓰는 두 가지만 둔다.
public enum SlackBlock: Codable, Sendable, Equatable {
    /// 본문 한 덩어리. mrkdwn 이다.
    case section(String)
    /// 작은 회색 글씨 한 줄. mrkdwn 이다.
    case context(String)

    private struct Text: Codable, Equatable {
        var type = "mrkdwn"
        var text: String
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, elements
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .section(let text):
            try container.encode("section", forKey: .type)
            try container.encode(Text(text: text), forKey: .text)
        case .context(let text):
            try container.encode("context", forKey: .type)
            try container.encode([Text(text: text)], forKey: .elements)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "context":
            let elements = try container.decode([Text].self, forKey: .elements)
            self = .context(elements.first?.text ?? "")
        default:
            self = .section(try container.decode(Text.self, forKey: .text).text)
        }
    }
}

extension Application {
    /// 스토어의 Slack 봇. 봇 토큰이 없으면 nil 이다.
    var slackBot: SlackBot? {
        alleyConfig.slackBotToken.map { SlackBot(client: client, token: $0) }
    }

    /// 봇의 Slack 핸들. 한 번 물어보면 프로세스가 끝날 때까지 기억한다.
    ///
    /// 앱 상세를 열 때마다 Slack 에 묻지 않는다. 봇 이름은 거의 바뀌지 않고, 바뀌어도
    /// 안내 문구 하나가 옛 이름으로 남을 뿐이다.
    ///
    /// **못 물어본 것도 잠시 기억한다.** Slack 이 막힌 동안 화면을 열 때마다 묻으면
    /// 그때마다 연결 시간만큼 화면이 늦어진다. 10분 뒤에 다시 묻는다.
    ///
    /// 토큰별로 기억한다. 토큰이 다르면 다른 봇이다.
    func slackBotHandle() async -> String? {
        guard let token = alleyConfig.slackBotToken, let bot = slackBot else { return nil }
        let now = Date()
        if let known = SlackBotHandles.known.withLockedValue({ $0[token] }) {
            if let handle = known.handle { return handle }
            if now.timeIntervalSince(known.at) < SlackBotHandles.retryAfter { return nil }
        }
        let handle = try? await bot.handle()
        SlackBotHandles.known.withLockedValue { $0[token] = (handle, now) }
        return handle
    }
}

private enum SlackBotHandles {
    static let retryAfter: TimeInterval = 600
    static let known = NIOLockedValueBox<[String: (handle: String?, at: Date)]>([:])
}
