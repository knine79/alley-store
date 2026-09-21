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
///     운영 알림   관리자        스토어가 정한다 (채널 **또는** DM)
///     개인 알림   나            내가 정한다 (DM 만)
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

    @Test("관리자 DM 을 고르면 채널로는 가지 않는다")
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

    /// 알 수 없는 값은 DM 으로 접는다. 채널은 등록해 둔 것이 있어야 닿고 DM 은
    /// 설정 없이 닿는다. 알 수 없는 상태에서는 닿는 쪽이 맞다.
    @Test("모르는 값은 관리자 DM 으로 접는다")
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
        try await withMigratedApp { app in
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

    /// 관리자가 남의 알림 설정을 대신 켜고 끌 자리는 없다. 화면이 자기 것만 읽고
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
