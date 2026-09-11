import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱을 지운다 (ADR-0041).
///
/// 지우면 버전·올린 파일·피드백·토큰까지 함께 사라집니다. 되돌릴 수 없습니다.
/// 그래서 **잃을 것이 있는 앱은 이름을 한 번 적게 합니다.** 그 검사는 서버가 합니다.
/// 브라우저 팝업만으로는 스크립트가 안 돌 때 아무것도 막지 못합니다.
public enum AppRemoval {
    /// 지우면 무엇이 사라지는가. 화면과 검사가 같은 값을 본다.
    public struct Cost: Sendable {
        public var versions: Int
        public var downloads: Int
        public var wasReleased: Bool

        /// 이름을 적게 할 만큼 잃을 것이 있는가.
        ///
        /// 한 번이라도 나갔거나 누군가 받아간 앱이다. 그런 앱은 지우는 순간 받아간
        /// 사람의 업데이트 경로가 끊긴다.
        public var needsTypedName: Bool { wasReleased || downloads > 0 }
    }

    /// 이 앱을 지우면 무엇을 잃는지 센다.
    public static func cost(of app: App, on database: any Database) async throws -> Cost {
        let appID = try app.requireID()
        let versions = try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .all()
        let versionIDs = try versions.map { try $0.requireID() }

        let downloads = versionIDs.isEmpty
            ? 0
            : try await Download.query(on: database)
                .filter(\.$version.$id ~~ versionIDs)
                .count()

        return Cost(
            versions: versions.count,
            downloads: downloads,
            // `released` 를 지금 달고 있지 않아도 한 번 나갔던 앱일 수 있다. 철회하면
            // `ready` 로 돌아오기 때문이다. 받아간 기록이 그 흔적을 대신 말해준다.
            wasReleased: versions.contains { $0.state == .released } || downloads > 0
        )
    }

    /// 앱 하나를 지운다.
    ///
    /// - Parameter typedName: 사람이 적어 보낸 앱 이름. 잃을 것이 있는 앱에서만 본다.
    public static func remove(
        _ app: App,
        typedName: String?,
        by user: User,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws {
        try app.requireManageAccess(for: user)

        let cost = try await cost(of: app, on: database)
        if cost.needsTypedName {
            let typed = (typedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed == app.name else {
                throw Abort(
                    .badRequest,
                    reason: """
                        지우려면 앱 이름 '\(app.name)' 을 그대로 적어야 합니다. \
                        이미 나간 앱이라 받아간 사람의 업데이트가 끊깁니다.
                        """
                )
            }
        }

        let appID = try app.requireID()
        let versions = try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .with(\.$artifacts)
            .all()

        // **스토리지를 먼저 치운다.** 행을 먼저 지우면 어떤 오브젝트가 남았는지
        // 알아낼 방법이 없어진다. 반대 순서로 실패하면 행이 남아서 다시 시도할 수 있다.
        var keys = versions.flatMap(\.artifacts).map(\.storageKey)
        keys += try await Feedback.query(on: database)
            .filter(\.$app.$id == appID)
            .all()
            .compactMap(\.screenshotKey)

        for key in keys {
            do {
                try await storage.delete(key: key)
            } catch {
                // 오브젝트가 이미 없을 수도 있고 스토리지가 잠깐 맛이 갔을 수도 있다.
                // 둘 다 앱을 치우는 것을 막을 이유는 아니다. 남은 것은 로그로 쫓는다.
                logger.warning(
                    "앱을 지우는 중 오브젝트를 치우지 못했습니다 [키: \(key), 이유: \(error)]"
                )
            }
        }

        // `downloads` 는 버전을 cascade 없이 참조한다. 여기서 먼저 끊어야 한다.
        let versionIDs = try versions.map { try $0.requireID() }
        if !versionIDs.isEmpty {
            try await Download.query(on: database)
                .filter(\.$version.$id ~~ versionIDs)
                .delete()
        }

        // 나머지(버전, 아티팩트, 멤버, 토큰, 피드백, 잡)는 외래 키 cascade 가 따라 지운다.
        try await app.delete(on: database)

        logger.notice(
            """
            앱을 지웠습니다 [id: \(appID), 이름: \(app.name), 번들 ID: \(app.bundleID), \
            버전 \(cost.versions)개, 받아간 기록 \(cost.downloads)건, 지운 사람: \(user.email)]
            """
        )
    }
}
