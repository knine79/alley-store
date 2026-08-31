import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 배포 토큰이 붙은 앱 하나를 만든다.
private struct DeploySetup {
    var owner: User
    var ownerToken: String
    var app: App
    var appID: UUID
    var deployToken: String
}

private func seedAppWithDeployToken(
    on app: Application,
    bundleID: String = "com.example.tool"
) async throws -> DeploySetup {
    let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
    let record = try await app.seedApp(bundleID: bundleID, name: "도구", owner: owner)
    let created = try await DeployTokenIssuing.issue(
        named: "github-actions",
        for: record,
        by: owner,
        on: app.db,
        logger: app.logger
    )
    return DeploySetup(
        owner: owner,
        ownerToken: ownerToken,
        app: record,
        appID: try record.requireID(),
        deployToken: created.value
    )
}

@Suite("배포 토큰 인증")
struct DeployTokenAuthTests {
    @Test("토큰이 자기 앱을 밝힌다")
    func tokenKnowsItsApp() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)

            // CLI 는 앱 ID 를 모른다. 토큰이 스스로 밝히는 것으로 시작한다.
            try await app.testing().test(
                .GET, APIPath.deployApp, headers: .bearer(setup.deployToken)
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(AppDTO.self)
                #expect(dto.bundleID == "com.example.tool")
            }
        }
    }

    @Test("모르는 토큰을 거절한다")
    func rejectsUnknownToken() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(
                .GET, APIPath.deployApp, headers: .bearer("alleyd_deadbeef")
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("폐기하면 즉시 막힌다")
    func revokedTokenStops() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)
            let stored = try #require(
                try await DeployToken.query(on: app.db).first()
            )
            try await DeployTokenIssuing.revoke(
                try stored.requireID(),
                ofApp: setup.app,
                by: setup.owner,
                on: app.db,
                logger: app.logger
            )

            try await app.testing().test(
                .GET, APIPath.deployApp, headers: .bearer(setup.deployToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("쓰면 마지막 사용 시각이 남는다")
    func recordsLastUse() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)

            try await app.testing().test(
                .GET, APIPath.deployApp, headers: .bearer(setup.deployToken)
            ) { _ in }

            // 안 쓰는 토큰을 찾아 지우려면 이 값이 있어야 한다.
            let stored = try #require(try await DeployToken.query(on: app.db).first())
            #expect(stored.lastUsedAt != nil)
        }
    }
}

@Suite("배포 토큰 권한 경계")
struct DeployTokenScopeTests {
    @Test("자기 앱에는 버전을 올릴 수 있다")
    func canUploadToOwnApp() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let setup = try await seedAppWithDeployToken(on: app)

            var ticket: UploadTicket?
            try await app.testing().test(
                .POST, APIPath.versions(ofApp: setup.appID),
                headers: .bearer(setup.deployToken),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateVersionRequest(shortVersion: "1.0.0", buildNumber: 1)
                    )
                }
            ) { response in
                #expect(response.status == .created)
                ticket = try response.content.decode(UploadTicket.self)
            }

            let versionID = try #require(ticket?.version.id)
            storage.place(
                key: ArtifactStorage.objectKey(
                    appID: setup.appID, versionID: versionID, kind: .unsigned
                ),
                size: 1024
            )

            try await app.testing().test(
                .POST, APIPath.completeUpload(versionID: versionID),
                headers: .bearer(setup.deployToken),
                beforeRequest: { request in
                    try request.content.encode(CompleteUploadRequest(sha256: "abc"))
                }
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("올린 버전은 토큰을 발급한 사람이 올린 것으로 남는다")
    func attributesVersionToIssuer() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedAppWithDeployToken(on: app)

            try await app.testing().test(
                .POST, APIPath.versions(ofApp: setup.appID),
                headers: .bearer(setup.deployToken),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateVersionRequest(shortVersion: "1.0.0", buildNumber: 1)
                    )
                }
            ) { #expect($0.status == .created) }

            // 파이프라인은 사람이 아니지만 그 파이프라인에 책임이 있는 사람은 있다.
            let version = try #require(try await Version.query(on: app.db).first())
            #expect(version.$createdBy.id == (try setup.owner.requireID()))
        }
    }

    @Test("남의 앱에는 손댈 수 없다")
    func cannotTouchOtherApps() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let mine = try await seedAppWithDeployToken(on: app, bundleID: "com.example.mine")
            let (other, _) = try await app.makeUser(email: "other@example.com", role: .developer)
            let otherApp = try await app.seedApp(
                bundleID: "com.example.other", name: "남의 앱", owner: other
            )

            // 앱의 존재조차 알려주지 않는다. 토큰 하나로 남의 앱을 훑는 것을 막는다.
            try await app.testing().test(
                .POST, APIPath.versions(ofApp: try otherApp.requireID()),
                headers: .bearer(mine.deployToken),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateVersionRequest(shortVersion: "1.0.0", buildNumber: 1)
                    )
                }
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("다운로드는 할 수 없다")
    func cannotDownload() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedAppWithDeployToken(on: app)
            let version = try await app.seedVersion(
                appID: setup.appID, short: "1.0.0", build: 1, state: .released, by: setup.owner
            )

            // 이력에 사람을 남기는 것이 그 경로의 목적 중 하나다.
            try await app.testing().test(
                .GET, APIPath.download(versionID: try version.requireID()),
                headers: .bearer(setup.deployToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("관리자 경로에는 통하지 않는다")
    func cannotReachAdmin() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)

            try await app.testing().test(
                .GET, "\(APIPath.adminRoot)/settings", headers: .bearer(setup.deployToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("워커 경로에는 통하지 않는다")
    func cannotReachWorkerQueue() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let setup = try await seedAppWithDeployToken(on: app)

            // 배포 토큰과 워커 토큰은 다른 신원이다. 서로의 문을 열지 못한다.
            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(setup.deployToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("출시와 철회는 할 수 있다")
    func canRelease() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)
            let version = try await app.seedVersion(
                appID: setup.appID, short: "1.0.0", build: 1, state: .ready, by: setup.owner
            )
            let versionID = try version.requireID()

            // 태그를 밀면 그대로 출시까지 가는 파이프라인이 자연스럽다.
            // 토큰이 이미 그 앱에 묶여 있어서 피해 범위가 늘지 않는다.
            try await app.testing().test(
                .POST, APIPath.release(versionID: versionID),
                headers: .bearer(setup.deployToken)
            ) { #expect($0.status == .ok) }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .released)
        }
    }
}

@Suite("배포 토큰 발급")
struct DeployTokenIssuingTests {
    @Test("앱을 관리하는 사람만 발급한다")
    func onlyManagersIssue() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)
            let (member, memberToken) = try await app.makeUser(
                email: "member@example.com", role: .developer
            )
            try await AppMember(
                appID: setup.appID, userID: try member.requireID()
            ).save(on: app.db)

            // 멤버는 자기 손으로 올릴 수 있지만, 사람 없이 도는 자격증명을 만드는 것은
            // 다른 무게의 일이다.
            try await app.testing().test(
                .POST, APIPath.deployTokens(ofApp: setup.appID),
                headers: .bearer(memberToken),
                beforeRequest: { request in
                    try request.content.encode(CreateDeployTokenRequest(name: "몰래"))
                }
            ) { #expect($0.status == .forbidden) }

            try await app.testing().test(
                .POST, APIPath.deployTokens(ofApp: setup.appID),
                headers: .bearer(setup.ownerToken),
                beforeRequest: { request in
                    try request.content.encode(CreateDeployTokenRequest(name: "정식"))
                }
            ) { #expect($0.status == .created) }
        }
    }

    @Test("발급한 값이 실제로 통한다")
    func issuedTokenWorks() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)

            var value: String?
            try await app.testing().test(
                .POST, APIPath.deployTokens(ofApp: setup.appID),
                headers: .bearer(setup.ownerToken),
                beforeRequest: { request in
                    try request.content.encode(CreateDeployTokenRequest(name: "새 토큰"))
                }
            ) { response in
                value = try response.content.decode(CreatedDeployToken.self).value
            }

            let issued = try #require(value)
            #expect(issued.hasPrefix("alleyd_"))
            try await app.testing().test(
                .GET, APIPath.deployApp, headers: .bearer(issued)
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("화면에서 발급하면 한 번만 보인다")
    func consoleShowsTokenOnce() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)
            let path = "/apps/\(setup.appID.uuidString)"

            try await app.testing().test(
                .POST, "\(path)/deploy-tokens", headers: .form(cookie: setup.ownerToken),
                beforeRequest: { request in
                    try request.content.encode(["name": "github-actions"], as: .urlEncodedForm)
                }
            ) { response in
                #expect(response.status == .created)
                #expect(response.body.string.contains("alleyd_"))
            }

            // 서버는 해시만 갖고 있어서 다음 화면에서 다시 보여줄 방법이 없다.
            try await app.testing().test(
                .GET, path, headers: .sessionCookie(setup.ownerToken)
            ) { #expect(!$0.body.string.contains("alleyd_")) }
        }
    }

    @Test("올릴 수만 있는 사람에게는 토큰 구역이 보이지 않는다")
    func tokenSectionIsForManagers() async throws {
        try await withMigratedApp { app in
            let setup = try await seedAppWithDeployToken(on: app)
            let (member, memberToken) = try await app.makeUser(
                email: "member@example.com", role: .developer
            )
            try await AppMember(
                appID: setup.appID, userID: try member.requireID()
            ).save(on: app.db)

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)", headers: .sessionCookie(memberToken)
            ) { #expect(!$0.body.string.contains("배포 토큰")) }

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)", headers: .sessionCookie(setup.ownerToken)
            ) { #expect($0.body.string.contains("배포 토큰")) }
        }
    }
}
