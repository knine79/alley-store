import AlleyShared
import Foundation
import JWT
import Testing
import VaporTesting

@testable import AlleyServer

/// 스토어 앱이 세션 토큰을 새로 받는다 (ADR-0069).
@Suite("세션 토큰 갱신")
struct SessionRenewalTests {
    private func sign(
        _ app: Application,
        userID: UUID,
        issuedAt: Date = Date(),
        authenticatedAt: Date? = nil
    ) async throws -> String {
        try await app.jwt.keys.sign(
            SessionToken(userID: userID, issuedAt: issuedAt, ttl: 3600, authenticatedAt: authenticatedAt)
        )
    }

    @Test("유효한 토큰을 내면 새 토큰을 준다")
    func renewsValidToken() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "user@example.com", role: .user)
            let loggedInAt = Date().addingTimeInterval(-3 * 24 * 60 * 60)
            let old = try await sign(
                app, userID: try user.requireID(),
                issuedAt: Date().addingTimeInterval(-60), authenticatedAt: loggedInAt
            )

            var renewed: String?
            try await app.testing().test(.POST, APIPath.tokenRenewal, headers: .bearer(old)) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(TokenExchangeResponse.self)
                #expect(body.user.email == "user@example.com")
                renewed = body.token
            }

            let token = try await app.jwt.keys.verify(try #require(renewed), as: SessionToken.self)
            // 수명은 새로 시작하고, 로그인 시각은 그대로 따라간다. 따라가지 않으면
            // 갱신할 때마다 90일이 다시 시작되어 끝이 없어진다.
            #expect(token.expiration.value > Date().addingTimeInterval(3000))
            #expect(abs(token.authenticationDate.timeIntervalSince(loggedInAt)) < 1)

            // 받은 토큰으로 바로 들어와진다.
            try await app.testing().test(.GET, APIPath.currentUser, headers: .bearer(try #require(renewed))) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test("로그인한 지 90일이 지나면 갱신하지 않는다")
    func refusesAfterMaximumAge() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "user@example.com", role: .user)
            // 지금 발급하는 토큰은 90일에서 만료가 잘려 여기 올 수 없다. 오는 것은 만료를
            // 자르기 전에 나간 토큰이나 `SESSION_TTL` 을 90일보다 길게 잡은 서버의 토큰이다.
            var payload = SessionToken(
                userID: try user.requireID(), issuedAt: Date(), ttl: 3600,
                authenticatedAt: Date().addingTimeInterval(-SessionToken.maximumAge - 60)
            )
            payload.expiration = .init(value: Date().addingTimeInterval(3600))
            let old = try await app.jwt.keys.sign(payload)

            try await app.testing().test(.POST, APIPath.tokenRenewal, headers: .bearer(old)) {
                // 401 이 아니다. 토큰은 아직 유효해서, 앱이 이 답을 보고 버리면 안 된다.
                #expect($0.status == .forbidden)
            }
            try await app.testing().test(.GET, APIPath.currentUser, headers: .bearer(old)) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test("만료가 잘리면 응답의 남은 시간도 그만큼 줄어든다")
    func expiresInReflectsCap() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "user@example.com", role: .user)
            // 90일까지 하루 남았다. `SESSION_TTL` 이 7일이어도 하루만 산다.
            let old = try await sign(
                app, userID: try user.requireID(),
                authenticatedAt: Date().addingTimeInterval(-SessionToken.maximumAge + 86_400)
            )

            try await app.testing().test(.POST, APIPath.tokenRenewal, headers: .bearer(old)) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(TokenExchangeResponse.self)
                #expect(abs(body.expiresIn - 86_400) < 10)
            }
        }
    }

    @Test("갱신한 토큰도 로그인한 지 90일을 넘겨 살지 않는다")
    func renewedTokenStopsAtMaximumAge() {
        let loggedInAt = Date(timeIntervalSince1970: 1_790_000_000)
        let nearCap = loggedInAt.addingTimeInterval(SessionToken.maximumAge - 3600)
        let token = SessionToken(
            userID: UUID(), issuedAt: nearCap, ttl: 7 * 24 * 3600, authenticatedAt: loggedInAt
        )
        #expect(token.expiration.value == loggedInAt.addingTimeInterval(SessionToken.maximumAge))
    }

    @Test("쿠키로는 갱신하지 않는다")
    func refusesCookie() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "user@example.com", role: .user)
            // 출처 검사를 통과하는 폼 요청으로 보낸다. 그냥 쿠키만 실으면 출처 검사가
            // 먼저 403 으로 막아서, 이 경로가 쿠키를 거르는지 확인할 수 없다.
            try await app.testing().test(.POST, APIPath.tokenRenewal, headers: .form(cookie: token)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test("토큰이 없거나 만료됐으면 갱신하지 않는다")
    func refusesMissingOrExpired() async throws {
        try await withMigratedApp { app in
            let (user, _) = try await app.makeUser(email: "user@example.com", role: .user)
            let expired = try await sign(
                app, userID: try user.requireID(), issuedAt: Date().addingTimeInterval(-7200)
            )

            try await app.testing().test(.POST, APIPath.tokenRenewal) {
                #expect($0.status == .unauthorized)
            }
            try await app.testing().test(.POST, APIPath.tokenRenewal, headers: .bearer(expired)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test("탈퇴 처리된 계정은 갱신하지 않는다")
    func refusesDeactivatedUser() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, token) = try await app.makeUser(email: "leaver@example.com", role: .user)
            try await AdminOperations.deactivate(target, by: admin, on: app.db, logger: app.logger)

            try await app.testing().test(.POST, APIPath.tokenRenewal, headers: .bearer(token)) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test("로그인 시각이 없는 예전 토큰은 발급 시각을 로그인 시각으로 본다")
    func legacyTokenUsesIssuedAt() throws {
        // `auth_time` 이 생기기 전에 발급된 토큰. 갱신된 적이 없으니 `iat` 가 로그인 시각이다.
        let issuedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let json = #"{"sub":"\#(UUID().uuidString)","iat":\#(issuedAt.timeIntervalSince1970),"exp":\#(issuedAt.timeIntervalSince1970 + 3600)}"#
        // JWT 의 시각은 1970년 기준 초다. `JSONDecoder` 기본값은 2001년 기준이다.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let token = try decoder.decode(SessionToken.self, from: Data(json.utf8))

        #expect(token.authenticatedAt == nil)
        #expect(token.authenticationDate == issuedAt)
        #expect(token.isRenewable(at: issuedAt.addingTimeInterval(SessionToken.maximumAge - 1)))
        #expect(!token.isRenewable(at: issuedAt.addingTimeInterval(SessionToken.maximumAge + 1)))
    }
}
