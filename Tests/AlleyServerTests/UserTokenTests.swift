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
                #expect(response.status == .ok)
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

            await UserTokenExpiryNotice.run(on: app)

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
            await UserTokenExpiryNotice.run(on: app)
            #expect(try await reload(soon).expiryNoticedAt == firstNotice)
        }
    }
}
