import AlleyShared
import Fluent
import Testing
import Vapor

@testable import AlleyServer

/// CLI 를 브라우저로 연결한다 (ADR-0064).
///
/// 여기서 보는 것은 **긴 수명 토큰이 주소를 타지 않는가**, **코드가 한 번만 먹는가**,
/// **남이 끼어들 자리가 없는가** 셋이다.
@Suite("CLI 기기 연결")
struct CLIAuthTests {
    @Test("확인 화면이 기기와 계정을 보여준다")
    func theConfirmScreenNamesTheDevice() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/auth/cli?port=51234&state=abc&device=my-mac-a3f9",
                headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("my-mac-a3f9"))
                #expect(response.body.string.contains("dev@example.com"))
            }
        }
    }

    /// 주소를 통째로 받으면 그 값으로 아무 데나 보내는 열린 리다이렉터가 된다.
    /// 포트만 받고, 그것도 범위를 본다.
    @Test("포트가 없거나 범위 밖이면 그리지 않는다")
    func aBadPortIsRefused() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            for query in ["", "?state=abc", "?port=80&state=abc", "?port=99999&state=abc"] {
                try await app.testing().test(
                    .GET, "/auth/cli\(query)", headers: .sessionCookie(token)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("확인 값이 없으면 그리지 않는다")
    func aMissingStateIsRefused() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .GET, "/auth/cli?port=51234", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// **긴 수명 토큰은 주소에 실리지 않는다.** 실리는 것은 2분 사는 일회용 코드다.
    @Test("승인하면 일회용 코드만 루프백으로 간다")
    func onlyAShortLivedCodeGoesBack() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)

            try await app.testing().test(
                .POST, "/auth/cli", headers: .form(cookie: token),
                body: .init(string: "port=51234&state=abc&device=my-mac")
            ) { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(location.hasPrefix("http://127.0.0.1:51234/?"))
                #expect(location.contains("state=abc"))
                // 사람 토큰이 주소에 실리면 브라우저 기록에 남는다.
                #expect(!location.contains(UserTokenPrefix.person))
            }
        }
    }

    @Test("코드를 사람 토큰으로 바꾼다")
    func theCodeBecomesAPersonToken() async throws {
        try await withMigratedApp { app in
            let (user, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let code = try await approve(on: app, session: token, device: "my-mac-a3f9")

            try await app.testing().test(
                .POST, "/api/v1/auth/cli/token",
                beforeRequest: { request in
                    try request.content.encode(["code": code, "device": "my-mac-a3f9"])
                }
            ) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(CLITokenResponse.self)
                #expect(body.token.hasPrefix(UserTokenPrefix.person))
                #expect(body.name == "my-mac-a3f9")
                #expect(body.email == "dev@example.com")
            }

            // 실제로 쓸 수 있어야 한다.
            let alive = try await UserToken.query(on: app.db)
                .filter(\.$user.$id == (try user.requireID()))
                .filter(\.$revokedAt == nil)
                .count()
            #expect(alive == 1)
        }
    }

    @Test("같은 코드는 두 번 먹지 않는다")
    func aCodeIsSpentOnce() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let code = try await approve(on: app, session: token, device: "my-mac")

            for expected in [HTTPStatus.ok, .unauthorized] {
                try await app.testing().test(
                    .POST, "/api/v1/auth/cli/token",
                    beforeRequest: { request in
                        try request.content.encode(["code": code, "device": "my-mac"])
                    }
                ) { response in
                    #expect(response.status == expected)
                }
            }
        }
    }

    /// 코드를 받아둔 뒤에 탈퇴 처리됐을 수 있다 (ADR-0061).
    @Test("탈퇴 처리된 계정에는 내주지 않는다")
    func aDepartedAccountGetsNothing() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (leaving, token) = try await app.makeUser(email: "gone@example.com", role: .developer)
            let code = try await approve(on: app, session: token, device: "my-mac")

            try await AdminOperations.deactivate(leaving, by: admin, on: app.db, logger: app.logger)

            try await app.testing().test(
                .POST, "/api/v1/auth/cli/token",
                beforeRequest: { request in
                    try request.content.encode(["code": code, "device": "my-mac"])
                }
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("로그인하지 않았으면 확인 화면을 내주지 않는다")
    func anonymousVisitorsAreSentAway() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, "/auth/cli?port=51234&state=abc") { response in
                #expect(response.status != .ok)
            }
        }
    }

    /// CLI 가 보낸 이름은 믿을 수 없다. 목록에 그대로 서는 값이다.
    @Test("기기 이름은 다듬어서 쓴다")
    func theDeviceNameIsCleaned() {
        #expect(CLIAuthController.deviceName("  my-mac  ") == "my-mac")
        #expect(CLIAuthController.deviceName("") == "alley CLI")
        #expect(!CLIAuthController.deviceName("a\nb").contains("\n"))
        #expect(
            CLIAuthController.deviceName(String(repeating: "가", count: 200)).count
                <= MePagesController.maximumTokenNameLength
        )
    }

    // MARK: - 보조

    /// 승인까지 하고 돌아온 코드를 꺼낸다.
    private func approve(on app: Application, session: String, device: String) async throws -> String {
        var code = ""
        try await app.testing().test(
            .POST, "/auth/cli", headers: .form(cookie: session),
            body: .init(string: "port=51234&state=abc&device=\(device)")
        ) { response in
            let location = try #require(response.headers.first(name: .location))
            let components = try #require(URLComponents(string: location))
            code = try #require(components.queryItems?.first { $0.name == "code" }?.value)
        }
        return code
    }
}
