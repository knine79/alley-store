import AlleyShared
import NIOCore
import NIOPosix
import Testing
import Vapor

@testable import AlleyServer

/// 메일이 실제로 나가는지 (ADR-0058).
///
/// **가짜 릴레이를 세워서 본다.** 다른 알림 테스트는 `NotificationChannel` 을 갈아
/// 끼워 "어디로 가는가" 만 보는데, 그러면 메일을 만드는 코드와 SMTP 로 내보내는
/// 코드가 한 번도 안 돌아간다. 제목을 안 넣거나 주소를 잘못 싸도 아무도 모른다.
///
/// 포트는 0 으로 열어 운영체제가 고르게 한다. 정해진 번호를 쓰면 같이 도는 다른
/// 것과 부딪친다.
@Suite("메일 알림")
struct EmailChannelTests {
    @Test("제목과 본문과 링크를 담아 보낸다")
    func sendsThroughRelay() async throws {
        let relay = try await FakeSMTPServer.start()
        defer { relay.stop() }

        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let config = AppConfig.SMTPConfig(
            hostname: "127.0.0.1",
            port: relay.port,
            username: nil,
            password: nil,
            fromAddress: "alley@example.com",
            fromName: "Alley",
            secure: "none"
        )
        app.configureSMTP(config)

        try await EmailChannel(application: app, config: config).send(
            NotificationMessage(
                title: "내 앱 1.0 (3) 서명이 실패했습니다",
                body: "entitlements 파일이 필요합니다.",
                link: "https://alley.example.com/apps/1"
            ),
            to: "dev@example.com"
        )

        let session = try #require(await relay.session())
        #expect(session.mailFrom.contains("alley@example.com"))
        #expect(session.rcptTo.contains("dev@example.com"))
        // 제목은 비 ASCII 라 인코딩돼서 나간다. 원문이 그대로 있을 것을 기대하지
        // 않고, 받는 쪽이 읽을 수 있는 형태로 실렸는지만 본다.
        #expect(session.data.contains("Subject:"))
        #expect(session.data.contains("https://alley.example.com/apps/1"))
    }

    /// 릴레이가 거절하면 우리 오류로 바꿔 던진다. 성공한 척 지나가면 아무도 안
    /// 받고 있는데 잘 되는 줄 아는 상태가 된다.
    @Test("릴레이가 거절하면 던진다")
    func rejectionThrows() async throws {
        let relay = try await FakeSMTPServer.start(rejectRecipients: true)
        defer { relay.stop() }

        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let config = AppConfig.SMTPConfig(
            hostname: "127.0.0.1",
            port: relay.port,
            username: nil,
            password: nil,
            fromAddress: "alley@example.com",
            fromName: "Alley",
            secure: "none"
        )
        app.configureSMTP(config)

        await #expect(throws: (any Error).self) {
            try await EmailChannel(application: app, config: config).send(
                NotificationMessage(title: "서명이 실패했습니다"),
                to: "nobody@example.com"
            )
        }
    }
}

/// 말을 받아주기만 하는 SMTP 서버.
///
/// 진짜 릴레이를 흉내 내지 않는다. 우리 쪽이 보낸 명령을 기록하고 규격대로 응답만
/// 한다. TLS 도 인증도 없다. 그것들은 이 테스트가 보려는 것이 아니다.
final class FakeSMTPServer: @unchecked Sendable {
    struct Session {
        var mailFrom = ""
        var rcptTo = ""
        var data = ""
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let recorder: Recorder
    let port: Int

    fileprivate actor Recorder {
        private var finished: Session?
        func finish(_ session: Session) { finished = session }
        func value() -> Session? { finished }
    }

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, recorder: Recorder) {
        self.group = group
        self.channel = channel
        self.recorder = recorder
        self.port = channel.localAddress?.port ?? 0
    }

    static func start(rejectRecipients: Bool = false) async throws -> FakeSMTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = Recorder()
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    Conversation(recorder: recorder, rejectRecipients: rejectRecipients)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return FakeSMTPServer(group: group, channel: channel, recorder: recorder)
    }

    func session() async -> Session? {
        // 마지막 응답을 보낸 뒤 기록이 닫히기까지 한 박자가 있다. 몇 번 들여다본다.
        for _ in 0..<50 {
            if let value = await recorder.value() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await recorder.value()
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    /// 한 연결에서 오가는 말.
    private final class Conversation: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let recorder: Recorder
        private let rejectRecipients: Bool
        private var session = Session()
        private var inData = false
        private var pending = ""

        init(recorder: Recorder, rejectRecipients: Bool) {
            self.recorder = recorder
            self.rejectRecipients = rejectRecipients
        }

        func channelActive(context: ChannelHandlerContext) {
            reply(context, "220 fake.example.com ESMTP")
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            pending += String(buffer: unwrapInboundIn(data))
            while let index = pending.range(of: "\r\n") {
                let line = String(pending[pending.startIndex..<index.lowerBound])
                pending = String(pending[index.upperBound...])
                handle(line, context: context)
            }
        }

        private func handle(_ line: String, context: ChannelHandlerContext) {
            if inData {
                if line == "." {
                    inData = false
                    let done = session
                    let recorder = self.recorder
                    Task { await recorder.finish(done) }
                    reply(context, "250 2.0.0 OK")
                } else {
                    session.data += line + "\n"
                }
                return
            }

            let upper = line.uppercased()
            switch true {
            case upper.hasPrefix("EHLO"), upper.hasPrefix("HELO"):
                // 여러 줄 응답. 마지막 줄만 하이픈이 없다.
                reply(context, "250-fake.example.com\r\n250 8BITMIME")
            case upper.hasPrefix("MAIL FROM"):
                session.mailFrom = line
                reply(context, "250 2.1.0 OK")
            case upper.hasPrefix("RCPT TO"):
                session.rcptTo = line
                reply(context, rejectRecipients ? "550 5.1.1 그런 사람 없습니다" : "250 2.1.5 OK")
            case upper.hasPrefix("DATA"):
                inData = true
                reply(context, "354 계속하세요")
            case upper.hasPrefix("QUIT"):
                reply(context, "221 2.0.0 안녕히")
                context.close(promise: nil)
            default:
                reply(context, "250 2.0.0 OK")
            }
        }

        private func reply(_ context: ChannelHandlerContext, _ text: String) {
            var buffer = context.channel.allocator.buffer(capacity: text.utf8.count + 2)
            buffer.writeString(text + "\r\n")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
