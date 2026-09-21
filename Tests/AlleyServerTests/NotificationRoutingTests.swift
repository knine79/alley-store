import AlleyShared
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 알림이 어디로 가는지.
///
/// 갈래가 셋이고 받는 사람도 정하는 사람도 다르다. 어느 하나가 다른 쪽 길로 새면
/// 받아야 할 사람이 못 받거나 받지 않아야 할 사람이 받는다.
///
///     운영 알림   관리자        스토어가 정한다 (채널 **또는** 관리자 개인)
///     개인 알림   나            내가 정한다 (Slack DM 또는 메일)
///     앱 소식     그 채널       앱마다 정한다
@Suite("알림이 정한 곳으로만 간다")
struct NotificationRoutingTests {
    private func seedGlobalTarget(on app: Application) async throws {
        let target = NotificationTarget(
            appID: nil,
            kind: .slack,
            name: "운영 채널",
            endpoint: "https://hooks.slack.com/services/x",
            createdByID: nil
        )
        try await target.save(on: app.db)
    }

    /// 설정 행을 읽거나 씨앗으로 만든다. 요청 밖에서 부르므로 `Request` 확장 대신
    /// 모델의 것을 직접 쓴다.
    private func settings(on app: Application) async throws -> StoreSettings {
        try await StoreSettings.loadOrSeed(
            on: app.db,
            seed: app.alleyConfig.store.seed,
            logger: app.logger
        )
    }

    /// **둘 다 보내지 않는다.** 같은 알림이 두 번 오면 한 번 오는 것보다 빨리
    /// 무시당한다.
    @Test("채널을 고르면 DM 으로는 가지 않는다")
    func channelExcludesDirectMessage() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await seedGlobalTarget(on: app)
            let stored = try await settings(on: app)
            stored.operationalAlerts = .channel
            try await stored.save(on: app.db)

            let channel = RecordingChannel(kind: .slack)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [channel, dm], logger: app.logger)

            await notifier.notifyOperators(NotificationMessage(title: "워커가 조용합니다"))

            #expect(channel.messages.count == 1)
            #expect(dm.messages.isEmpty)
        }
    }

    @Test("관리자 개인을 고르면 채널로는 가지 않는다")
    func adminsExcludeChannel() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await seedGlobalTarget(on: app)
            let stored = try await settings(on: app)
            stored.operationalAlerts = .admins
            try await stored.save(on: app.db)

            let channel = RecordingChannel(kind: .slack)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [channel, dm], logger: app.logger)

            await notifier.notifyOperators(NotificationMessage(title: "워커가 조용합니다"))

            #expect(dm.messages.count == 1)
            #expect(dm.endpoints == ["admin@example.com"])
            #expect(channel.messages.isEmpty)
        }
    }

    /// 관리자가 여럿이면 각자에게 간다. 하나에게만 가면 그 사람이 자리를 비웠을 때
    /// 아무도 모른다.
    @Test("관리자가 여럿이면 각자에게 간다")
    func everyAdminGetsIt() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "a@example.com", role: .admin)
            _ = try await app.makeUser(email: "b@example.com", role: .admin)
            _ = try await app.makeUser(email: "dev@example.com", role: .developer)
            let stored = try await settings(on: app)
            stored.operationalAlerts = .admins
            try await stored.save(on: app.db)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)

            await notifier.notifyOperators(NotificationMessage(title: "인증서가 곧 만료됩니다"))

            #expect(dm.endpoints.sorted() == ["a@example.com", "b@example.com"])
        }
    }

    /// 알 수 없는 값은 관리자 개인으로 접는다. 채널은 등록해 둔 것이 있어야 닿고
    /// 개인은 설정 없이 닿는다. 알 수 없는 상태에서는 닿는 쪽이 맞다.
    @Test("모르는 값은 관리자 개인으로 접는다")
    func unknownValueFallsBackToAdmins() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let stored = try await settings(on: app)
            stored.operationalAlertsRaw = "이런 값은 없다"
            try await stored.save(on: app.db)

            #expect(stored.operationalAlerts == .admins)
        }
    }

    // MARK: - 개인 알림

    /// 기본값이 서로 다르다. 서명 실패는 내가 올린 것만 오므로 켜두고, 피드백은
    /// 앱 하나를 여럿이 맡으면 여러 통이 가므로 꺼둔다.
    @Test("새 계정의 기본값은 서명 실패만 켜져 있다")
    func defaultPreferences() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let saved = try #require(try await User.find(try user.requireID(), on: app.db))
            #expect(saved.notifySigningFailure)
            #expect(!saved.notifyFeedback)
        }
    }

    /// 체크박스는 꺼져 있으면 아예 보내지지 않는다. 값이 없는 것을 "끈 것" 으로
    /// 읽지 않으면 한 번 켠 설정을 영영 못 끈다.
    @Test("보내지 않은 체크박스는 끈 것으로 읽는다")
    func missingCheckboxMeansOff() async throws {
        // 봇이 없으면 화면이 칸을 그리지 않고 서버도 거절한다. 여기서 보려는 것은
        // 값이 없을 때 어떻게 읽는가이므로 받을 수 있는 상태로 둔다.
        try await withMigratedApp(overrides: ["SLACK_BOT_TOKEN": "xoxb-test"]) { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/me/notifications",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["feedback": "on"], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .ok)
            }

            let saved = try #require(try await User.find(try user.requireID(), on: app.db))
            #expect(!saved.notifySigningFailure)
            #expect(saved.notifyFeedback)
        }
    }

    /// 화면이 칸을 그리지 않는 상태다. 여기까지 오는 길은 폼을 손으로 만드는
    /// 것뿐이고, 받아 봐야 켜도 아무 일이 없는 값이 저장된다.
    @Test("보낼 수단이 없으면 개인 알림을 정할 수 없다")
    func cannotChooseWithoutBot() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .POST, "/me/notifications",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["feedback": "on"], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// 같은 이유로 운영 알림도 막는다. 골라뒀으니 받고 있다고 믿게 두면 안 된다.
    @Test("보낼 수단이 없으면 관리자 개인을 고를 수 없다")
    func cannotChooseAdminsWithoutBot() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await app.testing().test(
                .POST, "/admin/notifications/target",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["target": "admins"], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .conflict)
                // 오류 화면이 아니라 그 화면에 이유가 붙는다.
                #expect(response.body.string.contains("Slack 봇도 메일도 연결되어 있지 않아"))
            }
        }
    }

    /// 관리자가 남의 알림 설정을 대신 켤 자리는 없다. 화면이 자기 것만 읽고
    /// 쓴다는 것을 경로로 확인한다.
    @Test("로그인하지 않으면 내 알림 화면에 들어갈 수 없다")
    func mySettingsNeedLogin() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/me/notifications") { response in
                #expect(response.status != .ok)
            }
        }
    }

    // MARK: - 운영 알림 화면

    @Test("관리자가 아니면 운영 알림 화면에 들어갈 수 없다")
    func operationalPageNeedsAdmin() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .GET, "/admin/notifications", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// **실패로 적지 않는다.** 이 화면을 보는 사람은 Slack 을 고른 적이 없고 지금
    /// 고를 수도 없다. "Slack 이 거절했습니다" 는 자기가 시킨 적 없는 일이 실패했다는
    /// 말로 읽힌다. 무엇이 갖춰지면 고를 수 있는지를 적는다.
    @Test("Slack DM 을 못 고르는 이유를 갖춰야 할 것으로 적는다")
    func explainsWhatWouldMakeSlackSelectable() {
        let email = "dev@example.com"

        // 관리자 설정 문제. 이 사람이 할 수 있는 것은 없고, 갖춰지면 고를 수 있다.
        let theirs = PersonalDelivery.unavailableReason(
            SlackDirectMessageChannel.ChannelError.rejected(
                api: "users.lookupByEmail", error: "invalid_auth"
            ),
            email: email
        )
        #expect(theirs.contains("지금 고를 수 없습니다"))
        #expect(theirs.contains("관리자가 Slack 봇을 설정하면"))
        // 시킨 적 없는 일이 실패했다고 읽히면 안 된다.
        #expect(!theirs.contains("거절했습니다"))
        // 코드는 남긴다. 관리자가 Slack 쪽에서 찾아볼 때 필요하다.
        #expect(theirs.contains("invalid_auth"))

        // 이메일이 어긋난 경우는 갖춰야 할 것이 다르다.
        let mine = PersonalDelivery.unavailableReason(
            SlackDirectMessageChannel.ChannelError.noSuchUser(email: email), email: email
        )
        #expect(mine.contains("지금 고를 수 없습니다"))
        #expect(mine.contains(email))
        #expect(mine.contains("이메일이 다르면"))

        let passing = PersonalDelivery.unavailableReason(
            SlackDirectMessageChannel.ChannelError.transport("연결 끊김"), email: email
        )
        #expect(passing.contains("잠시 뒤"))
    }

    // MARK: - 메일 (ADR-0058)

    /// 고른 수단이 스토어에 없으면 있는 것으로 간다. 고를 당시에 없던 수단이 나중에
    /// 생기고, 있던 수단이 사라진다. 그때 알림이 사라지면 끄지도 않은 알림이 조용히
    /// 멎는다.
    @Test("고른 수단이 없으면 있는 것으로 보낸다")
    func fallsBackToTheOnlyWayAvailable() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            // 기본값은 Slack DM 이다. 이 스토어에는 메일뿐이다.
            #expect(user.notifyVia == .slackDirectMessage)

            let mail = RecordingChannel(kind: .email)
            let notifier = Notifier(database: app.db, channels: [mail], logger: app.logger)

            await notifier.notify(person: user, message: NotificationMessage(title: "서명이 실패했습니다"))

            #expect(mail.endpoints == ["dev@example.com"])
        }
    }

    /// 둘 다 있으면 고른 대로 간다. 양쪽에 보내지 않는 이유는 운영 알림과 같다.
    @Test("둘 다 있으면 고른 쪽으로만 간다")
    func chosenWayWins() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            user.notifyVia = .email
            try await user.save(on: app.db)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let mail = RecordingChannel(kind: .email)
            let notifier = Notifier(database: app.db, channels: [dm, mail], logger: app.logger)

            await notifier.notify(person: user, message: NotificationMessage(title: "서명이 실패했습니다"))

            #expect(mail.messages.count == 1)
            #expect(dm.messages.isEmpty)
        }
    }

    /// 사람에게 보낼 수 없는 값이 들어와 있으면 기본으로 되돌린다. 웹훅 주소로는
    /// 그 사람에게만 보낼 수 없다.
    @Test("사람에게 못 쓰는 수단은 기본으로 되돌린다")
    func nonPersonalWayFoldsBack() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            user.notifyViaName = NotificationChannelKind.slack.rawValue
            #expect(user.notifyVia == .slackDirectMessage)
        }
    }

    /// 봇이 없어도 메일이 있으면 정할 수 있다. 하나뿐이면 화면이 고르게 하지 않으므로
    /// `via` 없이 온다.
    @Test("메일만 있어도 개인 알림을 정할 수 있다")
    func mailAloneIsEnoughToChoose() async throws {
        try await withMigratedApp(
            overrides: ["SMTP_HOST": "smtp.example.com", "SMTP_FROM": "alley@example.com"]
        ) { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/me/notifications",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["feedback": "on"], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .ok)
            }

            let saved = try #require(try await User.find(try user.requireID(), on: app.db))
            #expect(saved.notifyFeedback)
        }
    }

    /// 메일만 있는 스토어에서 Slack DM 을 고르면 아무 데도 가지 않는다. 화면이
    /// 그리지 않는 값이라 여기까지 오는 길은 폼을 손으로 만드는 것뿐이다.
    @Test("갖추지 않은 수단은 고를 수 없다")
    func cannotChooseAWayTheStoreLacks() async throws {
        try await withMigratedApp(
            overrides: ["SMTP_HOST": "smtp.example.com", "SMTP_FROM": "alley@example.com"]
        ) { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/me/notifications",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(["via": "slack_dm"], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// **메일에는 이름을 묻지 않는다.** 주소가 곧 받는 곳이라 목록에서 그것으로
    /// 알아본다. 따로 받으면 같은 것을 두 번 적게 된다.
    @Test("메일은 이름을 비워두면 주소를 쓴다")
    func mailTargetNamesItselfByAddress() async throws {
        try await withMigratedApp(
            overrides: ["SMTP_HOST": "smtp.example.com", "SMTP_FROM": "alley@example.com"]
        ) { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let mine = try await app.seedApp(
                bundleID: "com.example.named", name: "내 앱", owner: user
            )

            try await app.testing().test(
                .POST, "/apps/\(try mine.requireID())/notification-targets",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["kind": "email", "name": "", "endpoint": "team@example.com"],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            let saved = try #require(try await NotificationTarget.query(on: app.db).first())
            #expect(saved.name == "team@example.com")
        }
    }

    /// 웹훅은 주소를 가려야 해서 이름이 그 자리를 대신한다. 그래서 그쪽만 비울 수
    /// 없다. 비운 채로 만들면 목록에서 어느 채널인지 알 길이 없다.
    @Test("웹훅은 이름을 비울 수 없다")
    func webhookTargetStillNeedsAName() async throws {
        try await withMigratedApp { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let mine = try await app.seedApp(
                bundleID: "com.example.unnamed", name: "내 앱", owner: user
            )

            try await app.testing().test(
                .POST, "/apps/\(try mine.requireID())/notification-targets",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["name": "", "endpoint": "https://hooks.slack.com/services/x"],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .badRequest) }

            #expect(try await NotificationTarget.query(on: app.db).count() == 0)
        }
    }

    /// 메일 설정이 없으면 메일 주소를 등록해도 갈 곳이 없다. 화면도 칸을 그리지
    /// 않는다.
    @Test("메일 설정이 없으면 앱에 메일 주소를 달 수 없다")
    func cannotAttachMailWithoutSMTP() async throws {
        try await withMigratedApp { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let mine = try await app.seedApp(
                bundleID: "com.example.mine", name: "내 앱", owner: user
            )

            try await app.testing().test(
                .POST, "/apps/\(try mine.requireID())/notification-targets",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(
                        ["kind": "email", "name": "팀 메일", "endpoint": "team@example.com"],
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test("고른 값이 저장된다")
    func choosingTargetSaves() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .POST, "/admin/notifications/target",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["target": "channel"], as: .urlEncodedForm) }
            ) { response in
                #expect(response.status == .seeOther)
            }

            let stored = try await settings(on: app)
            #expect(stored.operationalAlerts == .channel)
        }
    }
}
