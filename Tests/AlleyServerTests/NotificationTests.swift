import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 보낸 것을 기억하는 가짜 채널.
final class RecordingChannel: NotificationChannel, @unchecked Sendable {
    let kind: NotificationChannelKind

    init(kind: NotificationChannelKind = .slack) {
        self.kind = kind
    }

    private let lock = NSLock()
    private var sent: [(NotificationMessage, String)] = []
    /// 켜면 보낼 때마다 실패한다.
    var shouldFail = false

    struct Boom: Error {}

    func send(_ message: NotificationMessage, to endpoint: String) async throws {
        if shouldFail { throw Boom() }
        record(message, endpoint)
    }

    private func record(_ message: NotificationMessage, _ endpoint: String) {
        lock.lock()
        defer { lock.unlock() }
        sent.append((message, endpoint))
    }

    var messages: [NotificationMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.0)
    }

    var endpoints: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.1)
    }
}

@Suite("알림 대상 등록")
struct NotificationTargetTests {
    private let webhook = "https://hooks.slack.com/services/T000/B000/xxxx"

    private func seedApp(on app: Application) async throws -> (owner: User, token: String, appID: UUID) {
        let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        return (owner, token, try record.requireID())
    }

    @Test("앱을 관리하는 사람이 대상을 붙인다")
    func ownerAddsTarget() async throws {
        try await withMigratedApp { app in
            let seeded = try await seedApp(on: app)

            try await app.testing().test(
                .POST, "\(APIPath.apiRoot)/apps/\(seeded.appID.uuidString)/notification-targets",
                headers: .bearer(seeded.token),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateNotificationTargetRequest(name: "팀 채널", endpoint: webhook)
                    )
                }
            ) { response in
                #expect(response.status == .created)
                let dto = try response.content.decode(NotificationTargetDTO.self)
                #expect(dto.name == "팀 채널")
                #expect(dto.appID == seeded.appID)
            }
        }
    }

    @Test("웹훅 주소를 목록에 되돌려주지 않는다")
    func neverEchoesEndpoint() async throws {
        try await withMigratedApp { app in
            let seeded = try await seedApp(on: app)
            _ = try await NotificationTargets.create(
                CreateNotificationTargetRequest(name: "팀 채널", endpoint: webhook),
                appID: seeded.appID,
                by: seeded.owner,
                on: app.db,
                logger: app.logger
            )

            // 웹훅 URL 은 그 채널에 글을 쓸 수 있는 자격증명이다.
            try await app.testing().test(
                .GET, "\(APIPath.apiRoot)/apps/\(seeded.appID.uuidString)/notification-targets",
                headers: .bearer(seeded.token)
            ) { response in
                #expect(!response.body.string.contains("hooks.slack.com"))
                #expect(response.body.string.contains("팀 채널"))
            }
        }
    }

    @Test("멤버는 대상을 붙일 수 없다")
    func membersCannotAdd() async throws {
        try await withMigratedApp { app in
            let seeded = try await seedApp(on: app)
            let (member, memberToken) = try await app.makeUser(
                email: "member@example.com", role: .developer
            )
            try await AppMember(appID: seeded.appID, userID: try member.requireID())
                .save(on: app.db)

            try await app.testing().test(
                .POST, "\(APIPath.apiRoot)/apps/\(seeded.appID.uuidString)/notification-targets",
                headers: .bearer(memberToken),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateNotificationTargetRequest(name: "몰래", endpoint: webhook)
                    )
                }
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("Slack 주소가 아니면 거절한다", arguments: [
        "https://example.com/webhook",
        "http://hooks.slack.com/services/T/B/x",
        "hooks.slack.com/services/T/B/x",
    ])
    func rejectsNonSlackEndpoint(_ endpoint: String) {
        // 오타 하나로 알림이 조용히 사라지는 것을 저장 시점에 막는다.
        #expect(throws: (any Error).self) {
            try NotificationTargets.validate(endpoint: endpoint, kind: .slack)
        }
    }

    @Test("전역 대상은 관리자만 다룬다")
    func globalTargetsAreAdminOnly() async throws {
        try await withMigratedApp { app in
            let (_, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let path = "\(APIPath.apiRoot)/admin/notification-targets"

            try await app.testing().test(.GET, path, headers: .bearer(devToken)) {
                #expect($0.status == .forbidden)
            }
            try await app.testing().test(
                .POST, path, headers: .bearer(adminToken),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateNotificationTargetRequest(name: "운영 채널", endpoint: webhook)
                    )
                }
            ) { #expect($0.status == .created) }
        }
    }
}

@Suite("알림 발송")
struct NotifierTests {
    private let webhook = "https://hooks.slack.com/services/T000/B000/xxxx"

    private func seedTarget(
        on app: Application,
        appID: UUID?
    ) async throws {
        let (user, _) = try await app.makeUser(
            email: "admin-\(UUID().uuidString.prefix(6))@example.com", role: .admin
        )
        _ = try await NotificationTargets.create(
            CreateNotificationTargetRequest(name: "채널", endpoint: webhook),
            appID: appID,
            by: user,
            on: app.db,
            logger: app.logger
        )
    }

    @Test("앱에 붙은 대상에게만 간다")
    func sendsToAppTargets() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let mine = try await app.seedApp(bundleID: "com.example.mine", name: "내 앱", owner: owner)
            let other = try await app.seedApp(
                bundleID: "com.example.other", name: "다른 앱", owner: owner
            )
            try await seedTarget(on: app, appID: try mine.requireID())
            try await seedTarget(on: app, appID: try other.requireID())

            let channel = RecordingChannel()
            let notifier = Notifier(database: app.db, channels: [channel], logger: app.logger)
            await notifier.notify(
                app: try mine.requireID(),
                message: NotificationMessage(title: "새 피드백")
            )

            #expect(channel.messages.count == 1)
            #expect(channel.messages.first?.title == "새 피드백")
        }
    }

    @Test("전역 대상은 앱 대상과 섞이지 않는다")
    func globalTargetsAreSeparate() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.tool", name: "도구", owner: owner
            )
            try await seedTarget(on: app, appID: try record.requireID())
            try await seedTarget(on: app, appID: nil)

            let channel = RecordingChannel()
            let notifier = Notifier(database: app.db, channels: [channel], logger: app.logger)
            await notifier.notifyGlobal(message: NotificationMessage(title: "워커가 조용합니다"))

            #expect(channel.messages.count == 1)
        }
    }

    @Test("보내다 실패해도 던지지 않고 이유를 남긴다")
    func recordsFailure() async throws {
        try await withMigratedApp { app in
            try await seedTarget(on: app, appID: nil)

            let channel = RecordingChannel()
            channel.shouldFail = true
            let notifier = Notifier(database: app.db, channels: [channel], logger: app.logger)

            // 알림 실패가 원래 하려던 일을 막으면, 사용자는 자기 글이 사라진 줄 안다.
            await notifier.notifyGlobal(message: NotificationMessage(title: "무엇"))

            let target = try #require(try await NotificationTarget.query(on: app.db).first())
            #expect(target.lastError != nil)
            #expect(target.lastSentAt == nil)
        }
    }

    @Test("성공하면 마지막 실패를 지운다")
    func clearsErrorAfterSuccess() async throws {
        try await withMigratedApp { app in
            try await seedTarget(on: app, appID: nil)
            let stored = try #require(try await NotificationTarget.query(on: app.db).first())
            stored.lastError = "예전 실패"
            try await stored.save(on: app.db)

            let notifier = Notifier(
                database: app.db, channels: [RecordingChannel()], logger: app.logger
            )
            await notifier.notifyGlobal(message: NotificationMessage(title: "무엇"))

            let after = try #require(try await NotificationTarget.query(on: app.db).first())
            #expect(after.lastError == nil)
            #expect(after.lastSentAt != nil)
        }
    }
}

@Suite("워커 감시")
struct WorkerWatchdogTests {
    private func worker(
        lastSeen: Date?,
        alerted: Date? = nil,
        revoked: Date? = nil,
        created: Date = Date()
    ) -> Worker {
        let worker = Worker(name: "build-mac", tokenHash: "hash", createdByID: nil)
        worker.lastSeenAt = lastSeen
        worker.alertedAt = alerted
        worker.revokedAt = revoked
        worker.createdAt = created
        return worker
    }

    private let now = Date()

    @Test("최근에 붙은 워커는 조용한 것이 아니다")
    func recentWorkerIsFine() {
        #expect(!WorkerWatchdog.isSilent(worker(lastSeen: now.addingTimeInterval(-60)), now: now))
    }

    @Test("오래 소식이 없으면 조용한 것이다")
    func silentWorkerIsDetected() {
        // 워커는 30초마다 하트비트를 보낸다. 10분이면 재시작으로 오알림이 나지 않는다.
        #expect(WorkerWatchdog.isSilent(worker(lastSeen: now.addingTimeInterval(-3600)), now: now))
    }

    @Test("이미 알린 워커를 또 알리지 않는다")
    func doesNotRepeatAlert() {
        let stale = now.addingTimeInterval(-3600)
        // 5분마다 같은 말을 반복하면 아무도 안 읽게 된다.
        #expect(!WorkerWatchdog.isSilent(worker(lastSeen: stale, alerted: now), now: now))
    }

    @Test("다시 붙었다가 또 끊기면 다시 알린다")
    func alertsAgainAfterRecovery() {
        let alerted = now.addingTimeInterval(-7200)
        let cameBack = now.addingTimeInterval(-3600)
        #expect(WorkerWatchdog.isSilent(worker(lastSeen: cameBack, alerted: alerted), now: now))
    }

    @Test("폐기한 워커는 조용한 것이 정상이다")
    func revokedWorkerIsIgnored() {
        #expect(
            !WorkerWatchdog.isSilent(
                worker(lastSeen: now.addingTimeInterval(-99999), revoked: now),
                now: now
            )
        )
    }

    @Test("등록만 하고 안 붙은 워커도 알린다")
    func neverConnectedIsReported() {
        // 설치가 덜 끝난 경우다. 등록 직후에는 울리지 않는다.
        #expect(
            !WorkerWatchdog.isSilent(worker(lastSeen: nil, created: now), now: now)
        )
        #expect(
            WorkerWatchdog.isSilent(
                worker(lastSeen: nil, created: now.addingTimeInterval(-3600)),
                now: now
            )
        )
    }
}
