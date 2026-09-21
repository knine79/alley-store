import AlleyShared
import Fluent
import Foundation
import Vapor

/// 사람에게 알릴 일 하나.
///
/// 채널마다 표현이 다르므로 문장을 미리 만들지 않고 조각으로 넘긴다. Slack 은
/// 굵은 글씨와 링크를 쓰고, 메일이 붙으면 제목과 본문으로 갈릴 것이다.
public struct NotificationMessage: Sendable {
    /// 한 줄 요약. 알림 목록에서 이것만 보인다.
    public var title: String
    /// 본문. 없으면 제목만 보낸다.
    public var body: String?
    /// 눌러서 갈 곳. 웹 콘솔의 해당 화면.
    public var link: String?

    public init(title: String, body: String? = nil, link: String? = nil) {
        self.title = title
        self.body = body
        self.link = link
    }
}

/// 알림을 실제로 보내는 곳.
///
/// 지금 구현은 웹훅 하나뿐이다. 메일을 붙이게 되면 이 프로토콜을 따르는 타입이
/// 하나 늘고, 부르는 쪽은 그대로다.
public protocol NotificationChannel: Sendable {
    var kind: NotificationChannelKind { get }
    func send(_ message: NotificationMessage, to endpoint: String) async throws
}

/// Slack Incoming Webhook.
///
/// 웹훅 URL 하나에 JSON 을 POST 하면 끝난다. 토큰도 앱 설치도 필요 없어서, 사내에
/// Slack 앱을 새로 만들 권한이 없는 사람도 채널 설정에서 웹훅 하나만 받아오면 된다.
public struct SlackWebhookChannel: NotificationChannel {
    public let kind: NotificationChannelKind = .slack

    private let client: any Client

    public init(client: any Client) {
        self.client = client
    }

    public enum ChannelError: Error, CustomStringConvertible {
        case rejected(status: Int, body: String)
        case transport(String)

        public var description: String {
            switch self {
            case .rejected(let status, let body):
                return "Slack 이 \(status) 를 돌려줬습니다: \(body)"
            case .transport(let detail):
                return "Slack 에 연결하지 못했습니다: \(detail)"
            }
        }
    }

    public func send(_ message: NotificationMessage, to endpoint: String) async throws {
        // Slack 은 mrkdwn 을 쓴다. HTML 도 마크다운도 아니라서 링크 형식이 독특하다.
        var text = "*\(message.title)*"
        if let body = message.body, !body.isEmpty {
            text += "\n\(body)"
        }
        if let link = message.link {
            text += "\n<\(link)|웹 콘솔에서 보기>"
        }

        let response: ClientResponse
        do {
            response = try await client.post(URI(string: endpoint)) { request in
                request.headers.contentType = .json
                try request.content.encode(["text": text])
            }
        } catch {
            throw ChannelError.transport(String(describing: error))
        }

        guard response.status.code < 300 else {
            throw ChannelError.rejected(
                status: Int(response.status.code),
                body: response.body.map { String(buffer: $0) } ?? ""
            )
        }
    }
}

/// 알림을 대상들에게 뿌린다.
///
/// **알림 실패가 원래 하려던 일을 막지 않는다.** 피드백을 남겼는데 Slack 이 죽어서
/// 500 이 돌아가면, 사용자는 자기 글이 사라진 줄 알고 다시 쓴다. 실패는 대상에
/// 기록하고 로그에 남길 뿐이다.
public struct Notifier: Sendable {
    private let database: any Database
    private let channels: [NotificationChannelKind: any NotificationChannel]
    private let logger: Logger

    public init(database: any Database, channels: [any NotificationChannel], logger: Logger) {
        self.database = database
        self.channels = Dictionary(
            channels.map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.logger = logger
    }

    /// 앱에 붙은 대상들에게 보낸다.
    public func notify(app appID: UUID, message: NotificationMessage) async {
        let targets = (try? await NotificationTarget.query(on: database)
            .filter(\.$app.$id == appID)
            .all()) ?? []
        await deliver(message, to: targets)
    }

    /// 전역 대상들에게 보낸다. 워커 알림처럼 앱과 무관한 것.
    public func notifyGlobal(message: NotificationMessage) async {
        let targets = (try? await NotificationTarget.query(on: database)
            .filter(\.$app.$id == nil)
            .all()) ?? []
        await deliver(message, to: targets)
    }

    /// 사람 한 명에게 보낸다.
    ///
    /// **대상 행을 거치지 않는다.** 앱에 붙이는 대상은 관리자가 만들어 두는 채널이고,
    /// 이쪽은 서버가 받는 사람을 아는 경우다. 서명이 실패하면 그 버전을 올린 사람이
    /// 고치는데, 그 사람이 미리 자기 대상을 만들어 뒀을 리 없다.
    ///
    /// 보낼 채널이 없으면 조용히 지나간다. 봇 토큰을 넣지 않은 스토어가 그렇고,
    /// 그때는 예전처럼 사람이 화면을 다시 보는 것으로 굴러간다.
    public func notify(person email: String, message: NotificationMessage) async {
        guard let channel = channels[.slackDirectMessage] else {
            logger.debug("사람에게 보내는 알림 채널이 없어 건너뜁니다 [\(email)]")
            return
        }
        do {
            try await channel.send(message, to: email)
        } catch {
            // **여기서 던지지 않는다.** 이 알림은 서명 실패를 기록하는 흐름 안에서
            // 불린다. 알림이 실패했다고 그 기록까지 되돌리면 잡이 멈춘 채로 남는다.
            logger.warning("알림을 보내지 못했습니다 [받는 사람: \(email), 이유: \(error)]")
        }
    }

    private func deliver(_ message: NotificationMessage, to targets: [NotificationTarget]) async {
        for target in targets {
            guard let channel = channels[target.kind] else {
                logger.warning("보낼 방법을 모르는 알림 대상 [\(target.kindName)]")
                continue
            }

            do {
                try await channel.send(message, to: target.endpoint)
                target.lastSentAt = Date()
                target.lastError = nil
            } catch {
                // 아무도 안 받고 있는데 잘 되는 줄 아는 상태를 만들지 않는다.
                let reason = String(describing: error)
                target.lastError = reason
                logger.warning("알림을 보내지 못했습니다 [대상: \(target.name), 이유: \(reason)]")
            }
            try? await target.save(on: database)
        }
    }
}

extension Application {
    /// 이 스토어가 쓸 수 있는 알림 채널들.
    ///
    /// 봇 토큰이 없으면 DM 채널이 빠진다. 요청 경로와 주기 작업이 같은 목록을 써야
    /// 한쪽에만 붙는 일이 없다.
    var notificationChannels: [any NotificationChannel] {
        var channels: [any NotificationChannel] = [SlackWebhookChannel(client: client)]
        if let token = alleyConfig.slackBotToken {
            channels.append(SlackDirectMessageChannel(client: client, botToken: token))
        }
        return channels
    }
}

extension Request {
    /// 이 요청에서 쓸 알림 발송기.
    var notifier: Notifier {
        Notifier(
            database: db,
            channels: application.notificationChannels,
            logger: logger
        )
    }

    /// 웹 콘솔의 해당 화면으로 가는 절대 주소.
    ///
    /// 알림에 상대 경로를 실으면 누를 수 없다.
    func consoleLink(_ path: String) -> String {
        application.alleyConfig.publicBaseURL.trimmingSuffix("/") + path
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var value = self
        while value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }
}
