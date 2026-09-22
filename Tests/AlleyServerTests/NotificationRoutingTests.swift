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

    @Test("개별 전송을 고르면 채널로는 가지 않는다")
    func peopleExcludeChannel() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await seedGlobalTarget(on: app)
            let stored = try await settings(on: app)
            stored.operationalAlerts = .people
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
            stored.operationalAlerts = .people
            try await stored.save(on: app.db)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)

            await notifier.notifyOperators(NotificationMessage(title: "인증서가 곧 만료됩니다"))

            #expect(dm.endpoints.sorted() == ["a@example.com", "b@example.com"])
        }
    }

    /// 알 수 없는 값은 개별 전송으로 접는다. 채널은 등록해 둔 것이 있어야 닿고
    /// 개별은 설정 없이 닿는다. 알 수 없는 상태에서는 닿는 쪽이 맞다.
    @Test("모르는 값은 개별 전송으로 접는다")
    func unknownValueFallsBackToAdmins() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let stored = try await settings(on: app)
            stored.operationalAlertsRaw = "이런 값은 없다"
            try await stored.save(on: app.db)

            #expect(stored.operationalAlerts == .people)
        }
    }

    // MARK: - 개인 알림

    /// **둘 다 켜짐이다** (ADR-0059). 기본이 꺼짐인 알림은 그 알림이 필요한 순간에
    /// 꺼져 있다. 소음을 겪은 사람이 끄면 되고, 그 사람은 끄는 자리를 찾아간다.
    @Test("새 계정은 둘 다 켜져 있다")
    func defaultPreferences() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let saved = try #require(try await User.find(try user.requireID(), on: app.db))
            #expect(saved.notifySigningFailure)
            #expect(saved.notifyFeedback)
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

    /// **보낼 수단이 없어도 정해둘 수는 있다.** 화면이 두 갈래를 회색으로라도
    /// 그리므로, 관리자가 나중에 붙이면 그때부터 그대로 간다. 막아두면 지금 정할 수
    /// 없다는 것만 알려줄 뿐 나중에 다시 오게 만든다.
    @Test("보낼 수단이 없어도 받을 알림은 정할 수 있다")
    func canStillChooseWhatToReceive() async throws {
        try await withMigratedApp { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .POST, "/me/notifications",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["feedback": "on"], as: .urlEncodedForm) }
            ) { #expect($0.status == .ok) }

            let saved = try #require(try await User.find(try user.requireID(), on: app.db))
            #expect(saved.notifyFeedback)
            #expect(!saved.notifySigningFailure)
        }
    }

    /// 같은 이유로 운영 알림도 막는다. 골라뒀으니 받고 있다고 믿게 두면 안 된다.
    @Test("보낼 수단이 없으면 개별 전송을 고를 수 없다")
    func cannotChooseAdminsWithoutBot() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await app.testing().test(
                .POST, "/admin/notifications/target",
                headers: .form(cookie: token),
                beforeRequest: { try $0.content.encode(["target": "people"], as: .urlEncodedForm) }
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

    /// **Slack 이 뭐라고 했는지는 적지 않는다.** 이 화면을 보는 사람은 Slack 을 부른
    /// 적이 없다. `invalid_auth` 같은 코드를 보여줘도 할 수 있는 것이 없다.
    @Test("내 알림에 Slack 응답 코드가 새지 않는다")
    func personalScreenHidesSlackInternals() async throws {
        try await withMigratedApp(
            overrides: [
                "SLACK_BOT_TOKEN": "xoxb-test",
                "SMTP_HOST": "smtp.example.com",
                "SMTP_FROM": "alley@example.com",
            ]
        ) { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/me/notifications", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                let body = response.body.string
                // 쓸 수 없는 것은 목록에서 빼지 않고 회색으로 남긴다. 빼버리면 왜
                // 메일 하나뿐인지 알 수 없다.
                #expect(body.contains("Slack DM"))
                #expect(body.contains("disabled"))
                // 코드도 API 이름도 나오지 않는다. "거절" 로는 검사하지 않는다 -
                // 템플릿 주석에도 그 글자가 들어 있어서 보이는 글이 아닌 것을 잡는다.
                #expect(!body.contains("invalid_auth"))
                #expect(!body.contains("users.lookupByEmail"))
                // 대신 무엇이 갖춰져야 하는지가 그 자리에 있다.
                #expect(body.contains("관리자가 Slack 봇을 연결하면"))
            }
        }
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
            #expect(user.notifyVia == [.slackDirectMessage])

            let mail = RecordingChannel(kind: .email)
            let notifier = Notifier(database: app.db, channels: [mail], logger: app.logger)

            await notifier.notify(person: user, message: NotificationMessage(title: "서명이 실패했습니다"))

            #expect(mail.endpoints == ["dev@example.com"])
        }
    }

    /// 고른 대로 간다. 하나만 골랐으면 하나로만 간다.
    @Test("고르지 않은 쪽으로는 가지 않는다")
    func chosenWayWins() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            user.notifyVia = [.email]
            try await user.save(on: app.db)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let mail = RecordingChannel(kind: .email)
            let notifier = Notifier(database: app.db, channels: [dm, mail], logger: app.logger)

            await notifier.notify(person: user, message: NotificationMessage(title: "서명이 실패했습니다"))

            #expect(mail.messages.count == 1)
            #expect(dm.messages.isEmpty)
        }
    }

    /// 사람에게 보낼 수 없는 값은 버린다. 웹훅 주소로는 그 사람에게만 보낼 수 없다.
    @Test("사람에게 못 쓰는 수단은 버린다")
    func nonPersonalWayIsDropped() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            user.notifyViaName = NotificationChannelKind.slack.rawValue
            #expect(user.notifyVia.isEmpty)
        }
    }

    /// **둘 다 고를 수 있다.** 남이 정해준 것이 아니라 자기가 고른 것이라, 두 번
    /// 오는 것도 본인이 정한 결과다.
    @Test("둘 다 고르면 둘 다 간다")
    func bothWaysWhenBothChosen() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            user.notifyVia = [.slackDirectMessage, .email]
            try await user.save(on: app.db)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let mail = RecordingChannel(kind: .email)
            let notifier = Notifier(database: app.db, channels: [dm, mail], logger: app.logger)

            await notifier.notify(person: user, message: NotificationMessage(title: "서명이 실패했습니다"))

            #expect(dm.messages.count == 1)
            #expect(mail.messages.count == 1)
        }
    }

    /// 한 갈래만 담던 시절의 값도 그대로 읽힌다.
    @Test("옛 값 하나짜리도 읽는다")
    func readsTheOldSingleValue() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            user.notifyViaName = "slack_dm"
            #expect(user.notifyVia == [.slackDirectMessage])
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

    /// 스토어가 갖추지 않은 수단은 골라도 저장되지 않는다. 화면이 회색으로 두는
    /// 값이라 여기까지 오는 길은 폼을 손으로 만드는 것뿐이다.
    @Test("갖추지 않은 수단은 저장되지 않는다")
    func doesNotStoreAWayTheStoreLacks() async throws {
        try await withMigratedApp(
            overrides: ["SMTP_HOST": "smtp.example.com", "SMTP_FROM": "alley@example.com"]
        ) { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/me/notifications",
                headers: .form(cookie: token),
                beforeRequest: {
                    try $0.content.encode(["via": ["slack_dm"]], as: .urlEncodedForm)
                }
            ) { #expect($0.status == .ok) }

            let saved = try #require(try await User.find(try user.requireID(), on: app.db))
            #expect(!saved.notifyVia.contains(.email))
            // 지금 쓸 수 없는 것은 폼이 무엇을 보내든 그대로 둔다. 새로 켜지도 않는다.
            #expect(saved.notifyVia == [.slackDirectMessage])
        }
    }

    /// **메일도 이름을 받는다.** 주소가 곧 받는 곳이라 한때 비울 수 있게 뒀는데,
    /// 별칭이나 메일링 리스트 주소는 그것만 봐서는 누구인지 알기 어렵다.
    @Test("이름 없이는 메일 주소도 등록할 수 없다")
    func mailTargetAlsoNeedsAName() async throws {
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
            ) { #expect($0.status == .badRequest) }

            #expect(try await NotificationTarget.query(on: app.db).count() == 0)
        }
    }

    /// 웹훅은 주소를 아예 가리므로 이름이 그 자리를 대신한다. 같은 이유로 비울 수
    /// 없지만, 목록에서 읽히는 모양은 다르다.
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

    /// 메일 주소는 자격증명이 아니라 그냥 주소다. 목록에 이름과 함께 선다. 웹훅
    /// 주소는 그 자체가 자격증명이라 내려주지 않는다.
    @Test("메일 주소는 목록에 보이고 웹훅 주소는 보이지 않는다")
    func onlyMailAddressesComeBack() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let mine = try await app.seedApp(
                bundleID: "com.example.both", name: "내 앱", owner: user
            )
            let appID = try mine.requireID()

            for (kind, endpoint) in [
                (NotificationChannelKind.email, "team@example.com"),
                (NotificationChannelKind.slack, "https://hooks.slack.com/services/x"),
            ] {
                try await NotificationTarget(
                    appID: appID, kind: kind, name: "\(kind.displayName) 대상",
                    endpoint: endpoint, createdByID: try user.requireID()
                ).save(on: app.db)
            }

            let rows = try await NotificationTarget.query(on: app.db).all().map { try $0.toDTO() }
            let mail = try #require(rows.first { $0.kind == .email })
            let webhook = try #require(rows.first { $0.kind == .slack })
            #expect(mail.endpoint == "team@example.com")
            #expect(webhook.endpoint == nil)
        }
    }

    /// **앱 대상은 웹훅만 받는다** (ADR-0059). 사람에게 보내는 길은 개별 전송이
    /// 맡고, 그쪽은 받는 사람이 각자 수단을 정하므로 등록할 주소가 없다.
    @Test("앱 대상에 메일 주소를 넣을 수 없다")
    func appTargetsTakeWebhooksOnly() async throws {
        try await withMigratedApp(
            overrides: ["SMTP_HOST": "smtp.example.com", "SMTP_FROM": "alley@example.com"]
        ) { app in
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
            ) { #expect($0.status == .badRequest) }

            #expect(try await NotificationTarget.query(on: app.db).count() == 0)
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
