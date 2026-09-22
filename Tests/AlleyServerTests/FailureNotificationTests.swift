import AlleyShared
import Fluent
import NIOCore
import NIOEmbedded
import Testing
import Vapor

@testable import AlleyServer

/// 서명이 실패하면 올린 사람에게 알린다.
///
/// 지금까지 알림은 피드백에만 붙어 있었다. 올려놓고 자리를 뜨면 실패한 줄 모르고
/// "아직 처리 중인가 보다" 로 남았다.
@Suite("서명 실패를 올린 사람에게 알린다")
struct FailureNotificationTests {

    /// **대상 행을 거치지 않는다.** 앱에 붙이는 대상은 관리자가 미리 만들어 두는
    /// 채널이고, 실패를 고칠 사람이 그것을 만들어 뒀을 리 없다.
    @Test("등록된 대상이 없어도 사람에게는 간다")
    func personGetsItWithoutTargets() async throws {
        try await withMigratedApp { app in
            let (uploader, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)

            await notifier.notify(
                person: uploader,
                message: NotificationMessage(title: "서명이 실패했습니다")
            )

            #expect(dm.messages.count == 1)
            #expect(dm.endpoints == ["dev@example.com"])
        }
    }

    /// 봇 토큰도 메일 설정도 넣지 않은 스토어가 여기로 온다. 예전처럼 사람이 화면을 다시 보는
    /// 것으로 굴러가야지, 실패를 기록하는 흐름이 여기서 멈추면 안 된다.
    @Test("보낼 채널이 없으면 조용히 지나간다")
    func missingChannelIsSkipped() async throws {
        try await withMigratedApp { app in
            let (uploader, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let webhookOnly = RecordingChannel(kind: .slack)
            let notifier = Notifier(database: app.db, channels: [webhookOnly], logger: app.logger)

            await notifier.notify(
                person: uploader,
                message: NotificationMessage(title: "서명이 실패했습니다")
            )

            #expect(webhookOnly.messages.isEmpty)
        }
    }

    /// 알림이 실패해도 던지지 않는다. 이 알림은 서명 실패를 기록하는 흐름 안에서
    /// 불리므로, 여기서 던지면 잡이 멈춘 채로 남는다.
    @Test("보내다 실패해도 던지지 않는다")
    func deliveryFailureIsSwallowed() async throws {
        try await withMigratedApp { app in
            let (uploader, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            dm.shouldFail = true
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)

            await notifier.notify(
                person: uploader,
                message: NotificationMessage(title: "서명이 실패했습니다")
            )

            #expect(dm.messages.isEmpty)
        }
    }

    /// DM 은 서버가 받는 사람을 아는 경우에만 쓴다. 관리자가 등록할 자리가 없다.
    @Test("Slack DM 은 알림 대상으로 등록할 수 없다")
    func directMessageCannotBeRegistered() {
        #expect(throws: (any Error).self) {
            try NotificationTargets.validate(
                endpoint: "https://hooks.slack.com/services/x",
                kind: .slackDirectMessage
            )
        }
    }

    /// 고를 수 없는 값이 화면 목록에 서면 안 된다.
    @Test("고를 수 있는 갈래에는 DM 이 없다")
    func directMessageIsNotSelectable() {
        #expect(!NotificationChannelKind.selectable.contains(.slackDirectMessage))
        #expect(NotificationChannelKind.selectable.contains(.slack))
    }

    // MARK: - Slack 이 답하는 방식

    /// **Slack 은 실패도 200 으로 준다.** 상태 코드만 보면 전부 성공으로 읽힌다.
    @Test("사용자를 찾지 못하면 그 사실을 말한다")
    func missingSlackUserIsReported() async throws {
        let channel = SlackDirectMessageChannel(
            client: StubSlackClient(lookup: #"{"ok":false,"error":"users_not_found"}"#),
            botToken: "xoxb-test"
        )

        await #expect(throws: SlackDirectMessageChannel.ChannelError.self) {
            try await channel.send(
                NotificationMessage(title: "서명이 실패했습니다"),
                to: "nobody@example.com"
            )
        }
    }

    @Test("글쓰기가 거절되면 그 사실을 말한다")
    func postRejectionIsReported() async throws {
        let channel = SlackDirectMessageChannel(
            client: StubSlackClient(
                lookup: #"{"ok":true,"user":{"id":"U1","name":"dev","real_name":"개발자"}}"#,
                post: #"{"ok":false,"error":"channel_not_found"}"#
            ),
            botToken: "xoxb-test"
        )

        await #expect(throws: SlackDirectMessageChannel.ChannelError.self) {
            try await channel.send(
                NotificationMessage(title: "서명이 실패했습니다"),
                to: "dev@example.com"
            )
        }
    }

    @Test("찾아서 보내면 통과한다")
    func happyPath() async throws {
        let stub = StubSlackClient(
            lookup: #"{"ok":true,"user":{"id":"U1","name":"dev","real_name":"개발자"}}"#,
            post: #"{"ok":true}"#
        )
        let channel = SlackDirectMessageChannel(client: stub, botToken: "xoxb-test")

        try await channel.send(
            NotificationMessage(title: "서명이 실패했습니다", link: "https://store.example.com/apps/1"),
            to: "dev@example.com"
        )

        // 두 번 부른다. 이메일로 찾고, 그 사용자에게 쓴다.
        #expect(stub.calls.count == 2)
        #expect(stub.calls[0].contains("users.lookupByEmail"))
        #expect(stub.calls[1].contains("chat.postMessage"))
    }

    /// 설정 화면이 "켜면 누구에게 가는가" 를 그 자리에서 보여준다. 보내지 않고
    /// 찾기만 한다.
    @Test("누구에게 가는지 미리 알려준다")
    func findsRecipientWithoutSending() async throws {
        let stub = StubSlackClient(
            lookup: #"{"ok":true,"user":{"id":"U1","name":"dev","real_name":"개발자"}}"#
        )
        let channel = SlackDirectMessageChannel(client: stub, botToken: "xoxb-test")

        let who = try await channel.findRecipient(email: "dev@example.com")

        #expect(who == "개발자 (@dev)")
        // 찾기만 한다. 확인하려고 열었는데 DM 이 오면 안 된다.
        #expect(stub.calls.count == 1)
    }

    /// 표시 이름이 없는 계정이 있다. 그때는 핸들만 보여준다.
    @Test("표시 이름이 없으면 핸들만 보여준다")
    func handleOnlyWhenNoRealName() async throws {
        let channel = SlackDirectMessageChannel(
            client: StubSlackClient(lookup: #"{"ok":true,"user":{"id":"U1","name":"dev"}}"#),
            botToken: "xoxb-test"
        )

        #expect(try await channel.findRecipient(email: "dev@example.com") == "@dev")
    }
}

/// Slack API 를 흉내낸다. 부른 주소를 기록하고 정해둔 본문을 돌려준다.
private final class StubSlackClient: Client, @unchecked Sendable {
    private let lookupBody: String
    private let postBody: String
    private let lock = NSLock()
    private var recorded: [String] = []

    init(lookup: String, post: String = #"{"ok":true}"#) {
        self.lookupBody = lookup
        self.postBody = post
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var eventLoop: any EventLoop { EmbeddedEventLoop() }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let url = request.url.string
        lock.lock()
        recorded.append(url)
        lock.unlock()

        let body = url.contains("users.lookupByEmail") ? lookupBody : postBody
        var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: .ok, headers: headers, body: buffer)
        )
    }
}
