import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

@Suite("버려진 draft 판단")
struct AbandonedDraftTests {
    private let now = Date()
    private let retention: TimeInterval = 72 * 3600

    private func version(state: VersionState, created: Date) -> Version {
        let version = Version(
            appID: UUID(),
            shortVersion: "1.0.0",
            buildNumber: 1,
            uploadKind: .unsigned,
            createdByID: UUID(),
            state: state
        )
        version.createdAt = created
        return version
    }

    @Test("보관 기간을 넘긴 draft 는 버려진 것이다")
    func oldDraftIsAbandoned() {
        let old = version(state: .draft, created: now.addingTimeInterval(-100 * 3600))
        #expect(DraftSweep.isAbandoned(old, now: now, retention: retention))
    }

    @Test("방금 만든 draft 는 건드리지 않는다")
    func freshDraftSurvives() {
        // 지금 올리고 있는 중이다.
        let fresh = version(state: .draft, created: now.addingTimeInterval(-60))
        #expect(!DraftSweep.isAbandoned(fresh, now: now, retention: retention))
    }

    @Test("업로드를 마친 버전은 오래돼도 건드리지 않는다")
    func uploadedVersionSurvives() {
        // draft 를 벗어났다는 것은 누군가 완료를 알렸다는 뜻이다.
        let old = version(state: .uploaded, created: now.addingTimeInterval(-100 * 3600))
        #expect(!DraftSweep.isAbandoned(old, now: now, retention: retention))
    }

    @Test("보관 기간은 설정을 따른다")
    func retentionIsConfigurable() {
        let draft = version(state: .draft, created: now.addingTimeInterval(-10 * 3600))
        #expect(!DraftSweep.isAbandoned(draft, now: now, retention: 24 * 3600))
        #expect(DraftSweep.isAbandoned(draft, now: now, retention: 3600))
    }
}

@Suite("방치된 draft 청소")
struct DraftSweepTests {
    /// 오래된 draft 하나를 만든다.
    ///
    /// `@Timestamp` 가 저장할 때 생성 시각을 덮어쓰므로, 저장한 뒤 시각을 되돌려
    /// 다시 저장한다.
    private func oldDraft(
        on app: Application,
        age: TimeInterval = 100 * 3600,
        build: Int = 1
    ) async throws -> (version: Version, key: String) {
        let (owner, _) = try await app.makeUser(
            email: "dev\(build)@example.com", role: .developer
        )
        let record = try await app.seedApp(
            bundleID: "com.example.tool\(build)", name: "도구", owner: owner
        )
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: build, state: .draft, by: owner
        )
        version.createdAt = Date().addingTimeInterval(-age)
        try await version.save(on: app.db)

        let key = ArtifactStorage.objectKey(
            appID: try record.requireID(),
            versionID: try version.requireID(),
            kind: .unsigned
        )
        return (version, key)
    }

    @Test("올라온 오브젝트까지 함께 지운다")
    func removesObjectAndRow() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (version, key) = try await oldDraft(on: app)
            // 올리기는 했는데 완료 통지가 오지 않은 경우다.
            storage.place(key: key, size: 4096)

            await DraftSweep.run(on: app)

            #expect(try await Version.find(try version.requireID(), on: app.db) == nil)
            #expect(try await storage.head(key: key) == nil)
        }
    }

    @Test("올린 것이 없어도 행은 지운다")
    func removesRowWithoutObject() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (version, _) = try await oldDraft(on: app)

            // 자리만 받아두고 아무것도 올리지 않은 경우다. 업로드 URL 은 이미 만료됐다.
            await DraftSweep.run(on: app)

            #expect(try await Version.find(try version.requireID(), on: app.db) == nil)
        }
    }

    @Test("보관 기간 안의 draft 는 남긴다")
    func keepsRecentDraft() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (version, key) = try await oldDraft(on: app, age: 60)
            storage.place(key: key, size: 4096)

            await DraftSweep.run(on: app)

            // 지금 올리고 있는 파일을 지우면 안 된다.
            #expect(try await Version.find(try version.requireID(), on: app.db) != nil)
            #expect(try await storage.head(key: key) != nil)
        }
    }

    @Test("보관 기간은 환경변수로 바꾼다")
    func honorsConfiguredRetention() async throws {
        try await withMigratedApp(overrides: ["DRAFT_RETENTION_HOURS": "1"]) { app in
            let storage = app.useFakeStorage()
            let (version, key) = try await oldDraft(on: app, age: 2 * 3600)
            storage.place(key: key, size: 4096)

            await DraftSweep.run(on: app)

            #expect(try await Version.find(try version.requireID(), on: app.db) == nil)
        }
    }

    @Test("스토리지가 죽었으면 아무것도 지우지 않는다")
    func keepsEverythingWhenStorageIsDown() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (version, key) = try await oldDraft(on: app)
            storage.place(key: key, size: 4096)
            storage.isUnavailable = true

            await DraftSweep.run(on: app)

            // 행을 지우면 오브젝트가 어느 키에 있는지 아는 근거가 사라진다.
            #expect(try await Version.find(try version.requireID(), on: app.db) != nil)
        }
    }

    @Test("업로드를 마친 버전은 지우지 않는다")
    func keepsUploadedVersion() async throws {
        try await withMigratedApp { app in
            let storage = app.useFakeStorage()
            let (version, key) = try await oldDraft(on: app)
            storage.place(key: key, size: 4096)
            version.state = .uploaded
            try await version.save(on: app.db)

            await DraftSweep.run(on: app)

            #expect(try await Version.find(try version.requireID(), on: app.db) != nil)
            #expect(try await storage.head(key: key) != nil)
        }
    }
}
