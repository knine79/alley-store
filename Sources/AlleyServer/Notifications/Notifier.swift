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

/// 앱에서 나가는 알림의 갈래.
///
/// **끄는 자리가 갈래마다 다르다.** 앱 하나를 여럿이 맡으면 피드백은 소음이 되기
/// 쉽고 서명 실패는 그렇지 않다. 하나로 묶으면 소음을 끄려다 실패까지 끄게 된다.
public enum AppAlertKind: Sendable {
    /// 새 피드백이 왔다.
    case feedback
    /// 서명이 최종적으로 실패했다.
    case signingFailure

    /// 이 사람이 이 갈래를 켜뒀나. 둘 다 기본은 켜짐이다 (ADR-0059).
    func isOn(for user: User) -> Bool {
        switch self {
        case .feedback: return user.notifyFeedback
        case .signingFailure: return user.notifySigningFailure
        }
    }
}

/// 알림을 실제로 보내는 곳.
///
/// 채널을 타입으로 둔 덕에 메일을 붙일 때 부르는 쪽이 그대로였다. 보내는 구현만
/// 하나 늘었다.
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

    /// 앱 소식. 그 앱이 정한 곳 **한 군데**로 보낸다 (ADR-0059).
    ///
    /// 운영 알림과 같은 규칙이다. 채널을 걸어뒀으면 채널로, 아니면 그 앱을 올릴 수
    /// 있는 사람들에게 한 명씩 간다. 개별로 갈 때는 각자 끈 것을 본다.
    public func notify(app: App, kind: AppAlertKind, message: NotificationMessage) async {
        guard let appID = try? app.requireID() else { return }
        switch app.alerts {
        case .channel:
            await notifyChannels(of: appID, message: message)
        case .people:
            await notifyEach(await uploaders(of: appID), about: kind, message: message)
        }
    }

    /// 앱에 붙은 채널들에게 보낸다.
    public func notifyChannels(of appID: UUID, message: NotificationMessage) async {
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

    /// 운영 알림. 스토어가 정한 곳 **한 군데**로 보낸다.
    ///
    /// 채널과 개별을 함께 보내지 않는다. 같은 알림이 두 번 오면 한 번 오는 것보다
    /// 빨리 무시당한다. 어느 쪽인지는 관리 화면에서 정한다.
    public func notifyOperators(_ message: NotificationMessage) async {
        let settings = try? await StoreSettings.find(StoreSettings.singletonID, on: database)
        switch settings?.operationalAlerts ?? .people {
        case .channel:
            await notifyGlobal(message: message)
        case .people:
            await notifyAdmins(message)
        }
    }

    /// 관리자 전원에게 각각 보낸다.
    ///
    /// 등록해 둘 것이 없어 설정을 잊어도 닿는다. 예전에는 전역 대상을 만들어 두지
    /// 않으면 워커가 죽어도 아무 데도 가지 않았고, 그 대상을 만드는 화면조차 없었다.
    ///
    /// **여기에는 끄는 자리가 없다.** 스토어가 멈추는 알림이라 받지 않겠다고 할 수
    /// 있는 성질이 아니다. 앱 알림은 소음이 될 수 있어 갈래마다 끄는 칸을 뒀다.
    private func notifyAdmins(_ message: NotificationMessage) async {
        let admins = (try? await User.query(on: database)
            .filter(\.$role == .admin)
            .all()) ?? []
        for admin in admins {
            await notify(person: admin, message: message)
        }
    }

    /// 이 앱을 올릴 수 있는 사람들. 오너와 멤버다.
    private func uploaders(of appID: UUID) async -> [User] {
        let memberIDs = (try? await AppMember.query(on: database)
            .filter(\.$app.$id == appID)
            .all()
            .map(\.$user.id)) ?? []
        let ownerID = try? await App.find(appID, on: database)?.$owner.id
        let ids = Set(memberIDs + [ownerID].compactMap { $0 })
        guard !ids.isEmpty else { return [] }
        return (try? await User.query(on: database)
            .filter(\.$id ~~ Array(ids))
            .all()) ?? []
    }

    /// 끄지 않은 사람에게만 한 통씩.
    private func notifyEach(
        _ people: [User],
        about kind: AppAlertKind,
        message: NotificationMessage
    ) async {
        for person in people where kind.isOn(for: person) {
            await notify(person: person, message: message)
        }
    }

    /// 사람 한 명에게 보낸다.
    ///
    /// **대상 행을 거치지 않는다.** 앱에 붙이는 대상은 관리자가 만들어 두는 채널이고,
    /// 이쪽은 서버가 받는 사람을 아는 경우다. 서명이 실패하면 그 버전을 올린 사람이
    /// 고치는데, 그 사람이 미리 자기 대상을 만들어 뒀을 리 없다.
    ///
    /// 보낼 채널이 없으면 조용히 지나간다. 봇 토큰도 메일 설정도 없는 스토어가
    /// 그렇고, 그때는 예전처럼 사람이 화면을 다시 보는 것으로 굴러간다.
    public func notify(person user: User, message: NotificationMessage) async {
        guard let channel = personalChannel(for: user) else {
            logger.debug("사람에게 보내는 알림 채널이 없어 건너뜁니다 [\(user.email)]")
            return
        }
        do {
            // Slack DM 도 메일도 받는 사람을 계정 이메일로 찾는다. DM 은 그 주소로
            // Slack 계정을 뒤지고, 메일은 그 주소로 보낸다.
            try await channel.send(message, to: user.email)
        } catch {
            // **여기서 던지지 않는다.** 이 알림은 서명 실패를 기록하는 흐름 안에서
            // 불린다. 알림이 실패했다고 그 기록까지 되돌리면 잡이 멈춘 채로 남는다.
            logger.warning("알림을 보내지 못했습니다 [받는 사람: \(user.email), 이유: \(error)]")
        }
    }

    /// 이 사람에게 실제로 쓸 채널.
    ///
    /// **고른 것이 없으면 있는 것으로 보낸다.** 고를 당시에 없던 수단이 나중에 생기고
    /// 있던 수단이 사라진다. 스토어가 Slack 봇을 떼고 메일만 남겼는데 예전에 고른
    /// 값 때문에 알림이 사라지면, 끄지도 않은 알림이 조용히 멎는다.
    ///
    /// 반대로 둘 다 있으면 고른 대로 간다. 양쪽에 보내지 않는 이유는 운영 알림과
    /// 같다. 두 번 오는 알림은 한 번 오는 알림보다 빨리 무시당한다.
    private func personalChannel(for user: User) -> (any NotificationChannel)? {
        if let chosen = channels[user.notifyVia] {
            return chosen
        }
        return NotificationChannelKind.personal.lazy.compactMap { channels[$0] }.first
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
    /// 설정하지 않은 것은 빠진다. 봇 토큰이 없으면 DM 이, 메일 설정이 없으면 메일이
    /// 빠진다. 요청 경로와 주기 작업이 같은 목록을 써야 한쪽에만 붙는 일이 없다.
    var notificationChannels: [any NotificationChannel] {
        var channels: [any NotificationChannel] = [SlackWebhookChannel(client: client)]
        if let token = alleyConfig.slackBotToken {
            channels.append(SlackDirectMessageChannel(client: client, botToken: token))
        }
        if let smtp = alleyConfig.smtp {
            channels.append(EmailChannel(application: self, config: smtp))
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
