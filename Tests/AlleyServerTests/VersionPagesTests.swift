import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("버전 업로드 화면")
struct VersionUploadPageTests {
    @Test("올릴 수 있는 사람에게만 열린다")
    func onlyUploadersCanOpen() async throws {
        try await withMigratedApp { app in
            let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(email: "other@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let path = "/apps/\(try record.requireID().uuidString)/versions/new"

            try await app.testing().test(.GET, path, headers: .sessionCookie(ownerToken)) {
                #expect($0.status == .ok)
            }
            // 등록 권한이 있어도 남의 앱에 올리는 것은 다른 문제다.
            try await app.testing().test(.GET, path, headers: .sessionCookie(otherToken)) {
                #expect($0.status == .forbidden)
            }
        }
    }

    @Test("다음 빌드 번호를 미리 채운다")
    func suggestsNextBuildNumber() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            try await app.seedVersion(appID: appID, short: "1.0.0", build: 7, state: .released, by: owner)

            // 마지막 번호가 몇이었는지 확인하러 목록으로 돌아가게 할 이유가 없다.
            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)/versions/new", headers: .sessionCookie(token)
            ) { #expect($0.body.string.contains("value=\"8\"")) }
        }
    }

    @Test("스크립트 없이 쓸 수 없다는 것을 알린다")
    func explainsScriptRequirement() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )

            // 브라우저가 스토리지로 직접 올리는 화면이라(ADR-0012) 폼만으로는 동작하지
            // 않는다. 눌러도 아무 일이 없는 것보다 왜 안 되는지 보이는 편이 낫다.
            try await app.testing().test(
                .GET, "/apps/\(try record.requireID().uuidString)/versions/new",
                headers: .sessionCookie(token)
            ) { #expect($0.body.string.contains("<noscript>")) }
        }
    }
}

@Suite("출시와 철회")
struct ReleaseActionTests {
    @Test("출시하면 상태가 released 로 간다")
    func releaseMovesState() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
            )
            let versionID = try version.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/release",
                headers: .form(cookie: token)
            ) { response in
                // 새로 고침이 같은 요청을 다시 보내지 않게 상세 화면으로 보낸다.
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/apps/\(appID.uuidString)")
            }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .released)
            #expect(stored.releasedAt != nil)
        }
    }

    @Test("철회하면 ready 로 돌아가고 출시 시각이 지워진다")
    func unreleaseGoesBackToReady() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
            )
            let versionID = try version.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/unrelease",
                headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            // 아티팩트는 남는다. 문제가 해결되면 다시 출시할 수 있어야 한다.
            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .ready)
            #expect(stored.releasedAt == nil)
        }
    }

    @Test("올릴 권한이 없으면 출시할 수 없다")
    func requiresUploadAccess() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(email: "other@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
            )

            try await app.testing().test(
                .POST,
                "/apps/\(appID.uuidString)/versions/\(try version.requireID().uuidString)/release",
                headers: .form(cookie: otherToken)
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("다른 앱 주소로는 출시할 수 없다")
    func rejectsMismatchedApp() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let mine = try await app.seedApp(bundleID: "com.example.mine", name: "내 앱", owner: owner)
            let other = try await app.seedApp(bundleID: "com.example.other", name: "다른 앱", owner: owner)
            let version = try await app.seedVersion(
                appID: try other.requireID(), short: "1.0.0", build: 1, state: .ready, by: owner
            )

            // 권한은 버전이 속한 앱으로 확인하므로 뚫리지는 않지만, 엉뚱한 화면으로
            // 돌아가는 경로를 열어둘 이유가 없다.
            try await app.testing().test(
                .POST,
                "/apps/\(try mine.requireID().uuidString)/versions/\(try version.requireID().uuidString)/release",
                headers: .form(cookie: token)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("아직 준비되지 않은 버전은 출시할 수 없다")
    func rejectsUnreadyVersion() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .draft, by: owner
            )

            // 화면에 버튼이 안 뜨는 상태지만, 오래된 화면에서 누를 수 있다.
            try await app.testing().test(
                .POST,
                "/apps/\(appID.uuidString)/versions/\(try version.requireID().uuidString)/release",
                headers: .form(cookie: token)
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test("상세 화면의 버튼은 상태를 따른다")
    func detailShowsMatchingButton() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let readyID = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
            ).requireID()
            let releasedID = try await app.seedVersion(
                appID: appID, short: "0.9.0", build: 2, state: .released, by: owner
            ).requireID()

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains("versions/\(readyID.uuidString)/release"))
                #expect(html.contains("versions/\(releasedID.uuidString)/unrelease"))
            }
        }
    }

    @Test("받기만 하는 사람에게는 출시 버튼이 없다")
    func viewersSeeNoActions() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
            )

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(userToken)
            ) { response in
                let html = response.body.string
                #expect(!html.contains("/unrelease"))
                #expect(!html.contains("/versions/new"))
            }
        }
    }
}

@Suite("서명 재시도")
struct RetryActionTests {
    /// 서명이 실패한 버전과 그 로그를 만든다.
    private func failedVersion(
        on app: Application
    ) async throws -> (token: String, appID: UUID, version: Version) {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let appID = try record.requireID()
        let version = try await app.seedVersion(
            appID: appID, short: "1.0.0", build: 1, state: .failed, by: owner
        )
        version.failureReason = "서명 identity 를 찾지 못했습니다."
        try await version.save(on: app.db)

        let job = try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)
        job.state = .failed
        job.log = "codesign: no identity found"
        try await job.save(on: app.db)

        return (token, appID, version)
    }

    @Test("실패한 버전을 다시 큐에 넣는다")
    func retryRequeues() async throws {
        try await withMigratedApp { app in
            let (token, appID, version) = try await failedVersion(on: app)
            let versionID = try version.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/retry",
                headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            // 올린 바이너리는 그대로 두고 상태만 되돌린다.
            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .uploaded)
            #expect(stored.failureReason == nil)

            let queued = try await SigningJob.query(on: app.db)
                .filter(\.$version.$id == versionID)
                .filter(\.$state == .queued)
                .count()
            #expect(queued == 1)
        }
    }

    @Test("완성본은 다시 시도해도 워커를 거치지 않는다")
    func signedRetrySkipsQueue() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .failed, by: owner,
                uploadKind: .signed
            )
            let versionID = try version.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/versions/\(versionID.uuidString)/retry",
                headers: .form(cookie: token)
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(try await Version.find(versionID, on: app.db))
            #expect(stored.state == .ready)
            #expect(try await SigningJob.query(on: app.db).count() == 0)
        }
    }

    @Test("실패하지 않은 버전은 다시 시도할 수 없다")
    func rejectsHealthyVersion() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            let appID = try record.requireID()
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .ready, by: owner
            )

            try await app.testing().test(
                .POST,
                "/apps/\(appID.uuidString)/versions/\(try version.requireID().uuidString)/retry",
                headers: .form(cookie: token)
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test("서명 로그는 올릴 수 있는 사람에게만 보인다")
    func logIsForUploaders() async throws {
        try await withMigratedApp { app in
            let (token, appID, _) = try await failedVersion(on: app)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)
            let (owner, _) = try await app.makeUser(email: "other@example.com", role: .developer)
            let visible = try await app.seedApp(
                bundleID: "com.example.public", name: "공개", owner: owner
            )
            try await app.seedVersion(
                appID: try visible.requireID(), short: "1.0.0", build: 1,
                state: .released, by: owner
            )

            // 올린 사람은 로그를 보고 스스로 고칠 수 있어야 한다.
            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { #expect($0.body.string.contains("codesign: no identity found")) }

            // 받기만 하는 사람에게는 워커 환경이 드러날 이유가 없다.
            try await app.testing().test(
                .GET, "/apps/\(try visible.requireID().uuidString)",
                headers: .sessionCookie(userToken)
            ) { #expect(!$0.body.string.contains("서명 로그")) }
        }
    }
}
