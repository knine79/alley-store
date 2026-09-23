import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 사람이 쥐는 토큰 (ADR-0060).
///
/// **이 토큰은 그 사람이다.** 인증에 성공하면 화면을 여는 요청과 구별되지 않는다.
/// 그래서 확인할 것은 "언제 그 사람이 아닌가" 쪽이다.
@Suite("사람 토큰")
struct UserTokenTests {
    /// 토큰을 하나 만들고 원문을 돌려준다.
    private func issue(
        for user: User,
        on app: Application,
        name: String = "노트북",
        expiresAt: Date = Date().addingTimeInterval(UserToken.lifetime)
    ) async throws -> String {
        let value = UserToken.generateToken()
        let token = UserToken(
            name: name,
            tokenHash: UserToken.hash(token: value),
            userID: try user.requireID(),
            expiresAt: expiresAt
        )
        try await token.save(on: app.db)
        return value
    }

    @Test("토큰으로 부르면 그 사람으로 인증된다")
    func actsAsThePerson() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let value = try await issue(for: user, on: app)

            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(value)) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("dev@example.com"))
            }
        }
    }

    @Test("폐기한 토큰은 막힌다")
    func revokedTokenIsRejected() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let value = try await issue(for: user, on: app)

            let token = try #require(
                try await UserToken.query(on: app.db)
                    .filter(\.$tokenHash == UserToken.hash(token: value))
                    .first()
            )
            token.revokedAt = Date()
            try await token.save(on: app.db)

            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(value)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test("만료한 토큰은 막힌다")
    func expiredTokenIsRejected() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let value = try await issue(
                for: user, on: app, expiresAt: Date().addingTimeInterval(-60)
            )

            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(value)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    /// 90일을 사는 값이라 나간 사람 손에 남겨둘 수 없다 (ADR-0061).
    @Test("계정을 끊으면 그 사람의 토큰도 함께 끊긴다")
    func deactivationRevokesTokens() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "leaver@example.com", role: .developer)
            let value = try await issue(for: target, on: app)

            try await AdminOperations.deactivate(
                target, by: admin, on: app.db, logger: app.logger
            )

            let token = try #require(
                try await UserToken.query(on: app.db)
                    .filter(\.$tokenHash == UserToken.hash(token: value))
                    .first()
            )
            #expect(token.revokedAt != nil)

            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(value)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    // MARK: - 못 하는 것

    /// 되돌릴 수 없는 일은 사람이 화면에서 한다 (ADR-0060).
    @Test("사람 토큰으로는 지우지 못한다")
    func deleteIsRejected() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (mate, _) = try await app.makeUser(email: "mate@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.keep", name: "지키는 앱", owner: owner
            )
            let appID = try registered.requireID()
            let mateID = try mate.requireID()
            try await AppMember(appID: appID, userID: mateID).save(on: app.db)

            let token = try await issue(for: owner, on: app)
            try await app.testing().test(
                .DELETE, "/api/v1/apps/\(appID.uuidString)/members/\(mateID.uuidString)",
                headers: .bearer(token)
            ) { response in
                #expect(response.status == .forbidden)
            }

            // 실제로 남아 있어야 한다. 막았다고 말만 하고 지워지면 더 나쁘다.
            let rows = try await AppMember.query(on: app.db)
                .filter(\.$app.$id == appID)
                .filter(\.$user.$id == mateID)
                .count()
            #expect(rows == 1)
        }
    }

    /// **이것이 허용목록으로 바꾼 이유다.** 배포 토큰은 만료가 없고 계정을 끊어도
    /// 살아남는다. 사람 토큰으로 그것을 만들 수 있으면 90일 수명과 퇴사 차단을 한
    /// 번에 넘어간다.
    @Test("사람 토큰으로는 다른 자격증명을 만들지 못한다")
    func cannotMintOtherCredentials() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .admin)
            let registered = try await app.seedApp(
                bundleID: "com.example.mint", name: "발급앱", owner: owner
            )
            let appID = try registered.requireID().uuidString
            let token = try await issue(for: owner, on: app)

            for path in [
                "/api/v1/apps/\(appID)/deploy-tokens",
                "/api/v1/apps/\(appID)/feed-tokens",
                "/api/v1/admin/workers",
            ] {
                try await app.testing().test(
                    .POST, path, headers: .bearer(token),
                    beforeRequest: { try $0.content.encode(["name": "훔친 것"]) }
                ) { response in
                    #expect(response.status == .forbidden)
                }
            }

            // 만들어진 것이 없어야 한다. 막았다고 말만 하고 생기면 더 나쁘다.
            #expect(try await DeployToken.query(on: app.db).count() == 0)
            #expect(try await FeedToken.query(on: app.db).count() == 0)
            #expect(try await Worker.query(on: app.db).count() == 0)
        }
    }

    /// 도구가 쓰는 경로는 그대로 열려 있어야 한다. 좁히다 필요한 것까지 막으면
    /// MCP 가 통째로 멈춘다.
    ///
    /// 서명 상태와 Sparkle 은 아직 이 브랜치에 없다. 목록에는 미리 올려두고, 실제로
    /// 열리는지는 그 경로를 만드는 쪽에서 확인한다.
    @Test("도구가 쓰는 경로는 열려 있다")
    func toolPathsStayOpen() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.open", name: "열린앱", owner: owner
            )
            let appID = try registered.requireID().uuidString
            let token = try await issue(for: owner, on: app)

            for path in [
                "/api/v1/me",
                "/api/v1/apps",
                "/api/v1/apps/\(appID)",
                "/api/v1/apps/\(appID)/versions",
                "/api/v1/apps/\(appID)/feedback",
            ] {
                try await app.testing().test(.GET, path, headers: .bearer(token)) { response in
                    #expect(response.status == .ok)
                }
            }
        }
    }

    /// 앱 삭제는 화면 경로에만 있다. 그래서 경로 자체를 막는다.
    @Test("사람 토큰은 화면 경로에서 인증되지 않는다")
    func webRoutesNeedASession() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let registered = try await app.seedApp(
                bundleID: "com.example.web", name: "화면앱", owner: owner
            )
            let token = try await issue(for: owner, on: app)

            try await app.testing().test(
                .GET, "/apps/\(try registered.requireID().uuidString)", headers: .bearer(token)
            ) { response in
                // 열려 있지 않은 경로라고 분명히 말한다. `!= .ok` 로 두면 500 에도
                // 통과해서, 가드가 사라진 것과 터진 것을 구별하지 못한다.
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - 내 토큰 화면

    @Test("발급하면 원문이 그 화면에만 보인다")
    func issuedValueShowsOnce() async throws {
        try await withMigratedApp { app in
            let (_, session) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/me/tokens",
                headers: .form(cookie: session),
                beforeRequest: {
                    try $0.content.encode(["name": "노트북"], as: .urlEncodedForm)
                }
            ) { response in
                // 만든 것이 있으면 201. 배포 토큰 발급과 같다.
                #expect(response.status == .created)
                #expect(response.body.string.contains(UserToken.prefix))
            }

            // 목록을 다시 열면 원문은 없다. 해시만 저장한다.
            try await app.testing().test(.GET, "/me/tokens", headers: .sessionCookie(session)) {
                #expect(!$0.body.string.contains(UserToken.prefix))
                #expect($0.body.string.contains("노트북"))
            }
        }
    }

    @Test("남의 토큰은 폐기할 수 없다")
    func cannotRevokeSomeoneElsesToken() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let (_, otherSession) = try await app.makeUser(
                email: "other@example.com", role: .developer
            )
            let value = try await issue(for: owner, on: app)
            let token = try #require(
                try await UserToken.query(on: app.db)
                    .filter(\.$tokenHash == UserToken.hash(token: value))
                    .first()
            )
            let tokenID = try token.requireID().uuidString

            try await app.testing().test(
                .POST, "/me/tokens/\(tokenID)/revoke", headers: .form(cookie: otherSession)
            ) { response in
                #expect(response.status == .notFound)
            }

            let reloaded = try #require(try await UserToken.find(try token.requireID(), on: app.db))
            #expect(reloaded.revokedAt == nil)
        }
    }

    // MARK: - 만료 예고

    /// 닿을 길이 없으면 알린 것으로 적지 않는다. 적어버리면 관리자가 나중에 메일을
    /// 붙여도 그 사람은 끝까지 못 듣는다.
    @Test("보내지 못했으면 알린 것으로 적지 않는다")
    func doesNotMarkWhatItCouldNotSend() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let value = try await issue(
                for: user, on: app, name: "곧 만료",
                expiresAt: Date().addingTimeInterval(3 * 24 * 3600)
            )

            // 스토어에 Slack 도 메일도 없다. 보낼 데가 없다.
            await UserTokenExpiryNotice.run(on: app)

            let token = try #require(
                try await UserToken.query(on: app.db)
                    .filter(\.$tokenHash == UserToken.hash(token: value))
                    .first()
            )
            #expect(token.expiryNoticedAt == nil)
        }
    }

    @Test("만료가 가까운 것만 알리고, 한 번만 알린다")
    func noticesOnlyOnce() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let soon = try await issue(
                for: user, on: app, name: "곧 만료",
                expiresAt: Date().addingTimeInterval(3 * 24 * 3600)
            )
            let later = try await issue(
                for: user, on: app, name: "아직 멀었다",
                expiresAt: Date().addingTimeInterval(60 * 24 * 3600)
            )

            // 실제로 닿는 채널을 하나 넣는다. 없으면 아무 데도 가지 않고, 그때는
            // 알린 것으로 적지 않는 것이 맞다 (바로 위 시험).
            let dm = RecordingChannel(kind: .slackDirectMessage)
            await UserTokenExpiryNotice.run(
                on: app,
                notifier: Notifier(database: app.db, channels: [dm], logger: app.logger)
            )
            #expect(dm.endpoints == ["dev@example.com"])

            func reload(_ value: String) async throws -> UserToken {
                try #require(
                    try await UserToken.query(on: app.db)
                        .filter(\.$tokenHash == UserToken.hash(token: value))
                        .first()
                )
            }

            let noticed = try await reload(soon)
            #expect(noticed.expiryNoticedAt != nil)
            #expect(try await reload(later).expiryNoticedAt == nil)

            // 두 번째로 쓸고 지나가도 기록은 그대로다. 같은 말을 이레 동안 매일
            // 보내지 않는다.
            let firstNotice = noticed.expiryNoticedAt
            await UserTokenExpiryNotice.run(
                on: app,
                notifier: Notifier(database: app.db, channels: [dm], logger: app.logger)
            )
            #expect(try await reload(soon).expiryNoticedAt == firstNotice)
            // 두 번째로 쓸고 지나가도 또 보내지 않는다.
            #expect(dm.endpoints == ["dev@example.com"])
        }
    }
}
