import Fluent
import Vapor

/// 앱 상세의 "출시 소식 알림" 과 출시 팝업이 쓰는 값 (ADR-0075).
struct ReleaseNewsContext: Encodable {
    /// 스토어에 Slack 봇이 연결되어 있나. 없으면 채널을 넣어도 보낼 수 없다.
    var botReady: Bool
    /// 채널에 초대할 봇의 핸들. 앞에 `@` 를 붙여 보여준다. 못 물어봤으면 nil.
    var botHandle: String?
    var channels: [AlertChannelRow]
    /// 팝업에 적을 채널 목록. `#a, #b` 처럼 이어 붙인 한 줄이다.
    ///
    /// 템플릿에서 이어 붙이면 마지막 쉼표를 뺄 방법이 없다.
    var channelList: String
    /// 채널을 새로 넣을 곳.
    var addAction: String
    /// 채널을 넣다 막혔을 때 그 자리에 띄울 말.
    var error: String?
    /// 출시할 때 팝업을 띄울까. 스토어 앱은 알리지 않으므로 띄우지 않는다.
    var asksOnRelease: Bool
}

extension ReleaseNewsContext {
    static func make(
        app: App,
        isStoreApp: Bool,
        canManage: Bool,
        error: String?,
        on request: Request
    ) async throws -> ReleaseNewsContext {
        let appID = try app.requireID()
        let channels = try await ReleaseChannel.query(on: request.db)
            .filter(\.$app.$id == appID)
            .sort(\.$name)
            .all()
        let botReady = request.application.slackBot != nil
        return ReleaseNewsContext(
            botReady: botReady,
            // 초대 안내는 관리 섹션에만 나온다. 출시만 하는 사람의 화면이 Slack 을 기다릴
            // 이유가 없다.
            botHandle: botReady && canManage ? await request.application.slackBotHandle() : nil,
            channels: channels.compactMap { channel in
                guard let id = try? channel.requireID() else { return nil }
                return AlertChannelRow(
                    name: "#\(channel.name)",
                    lastSentAt: channel.lastSentAt.map { DateStyle.minute.string(from: $0) },
                    lastError: channel.lastError,
                    deletePath: "/apps/\(appID.uuidString)/release-channels/\(id.uuidString)/delete"
                )
            },
            channelList: channels.map { "#\($0.name)" }.joined(separator: ", "),
            addAction: "/apps/\(appID.uuidString)/release-channels",
            error: error,
            asksOnRelease: !isStoreApp
        )
    }
}

struct ReleaseChannelFormValues: Content {
    var channel: String?
}

extension AppPagesController {
    /// 출시 소식 채널을 넣는다.
    ///
    /// **넣을 때 봇이 그 채널에 있는지 본다.** 봇을 초대하지 않은 채널을 받아두면, 처음
    /// 출시할 때에야 실패를 알게 된다. 그때는 이미 출시가 끝난 뒤라 소식을 다시 올릴
    /// 길이 없다.
    @Sendable
    func addReleaseChannel(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)
        let appID = try app.requireID()

        guard let bot = request.application.slackBot else {
            return try await releaseNewsError(
                "Slack 봇이 연결되어 있지 않아 출시 소식을 보낼 수 없습니다.",
                status: .conflict, on: request
            )
        }

        let input = (try? request.content.decode(ReleaseChannelFormValues.self))?.channel ?? ""
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try await releaseNewsError(
                "채널 이름이 비어 있습니다. #team-releases 처럼 적으세요.",
                status: .badRequest, on: request
            )
        }

        let channel: SlackBot.Channel
        do {
            channel = try await bot.findChannel(input)
        } catch let error as SlackBot.BotError {
            return try await releaseNewsError(error.description, status: .badRequest, on: request)
        }

        guard channel.isMember else {
            let handle = await request.application.slackBotHandle().map { "@\($0)" } ?? "스토어 봇"
            return try await releaseNewsError(
                "#\(channel.name) 에 \(handle) 봇이 없습니다. 채널에서 /invite \(handle) 를 보낸 뒤 다시 추가하세요.",
                status: .conflict, on: request
            )
        }

        // **등록하는 사람도 그 채널에 있어야 한다.** 봇만 보면 다른 팀이 봇을 초대해 둔
        // 채널을 아무 앱 관리자나 걸 수 있다. 그러면 남의 채널에 엉뚱한 앱 소식이
        // 스토어 이름으로 올라가고, ID 로 넣으면 비공개 채널 이름까지 알게 된다.
        do {
            let person = try await bot.userID(email: user.email)
            guard try await bot.isMember(userID: person, of: channel.id) else {
                return try await releaseNewsError(
                    "#\(channel.name) 에 들어가 있는 사람만 등록할 수 있습니다. 채널에 들어간 뒤 다시 추가하세요.",
                    status: .forbidden, on: request
                )
            }
        } catch let error as SlackBot.BotError {
            return try await releaseNewsError(error.description, status: .badRequest, on: request)
        }

        let exists = try await ReleaseChannel.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$slackChannelID == channel.id)
            .count() > 0
        if !exists {
            try await ReleaseChannel(
                appID: appID,
                slackChannelID: channel.id,
                name: channel.name,
                createdByID: try user.requireID()
            ).save(on: request.db)
            request.logger.notice(
                "출시 소식 채널 추가 [\(app.bundleID), #\(channel.name), 등록: \(user.email)]"
            )
        }
        return request.redirect(to: "/apps/\(appID.uuidString)#release-news")
    }

    @Sendable
    func removeReleaseChannel(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try app.requireManageAccess(for: user)
        let appID = try app.requireID()

        guard let channelID = request.parameters.get("channelID", as: UUID.self),
              let channel = try await ReleaseChannel.query(on: request.db)
                .filter(\.$id == channelID)
                // 남의 앱 채널을 이 앱 주소로 지우지 못하게 범위를 함께 건다.
                .filter(\.$app.$id == appID)
                .first()
        else {
            throw Abort(.notFound, reason: "출시 소식 채널을 찾을 수 없습니다.")
        }
        try await channel.delete(on: request.db)
        return request.redirect(to: "/apps/\(appID.uuidString)#release-news")
    }

    /// 목록을 그대로 두고 왜 안 되는지만 그 섹션 위에 띄운다.
    private func releaseNewsError(
        _ message: String,
        status: HTTPResponseStatus,
        on request: Request
    ) async throws -> Response {
        let view = try await renderDetail(on: request, issuedToken: nil, releaseNewsError: message)
        return htmlResponse(view, status: status)
    }
}
