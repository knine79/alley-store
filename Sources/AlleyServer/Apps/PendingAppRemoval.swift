import AlleyShared
import Fluent
import Foundation
import Vapor

/// 확정되지 못한 등록을 치운다 (ADR-0039).
///
/// dmg 로 올리면 번들 ID 가 임시값인 채로 앱이 만들어지고, 워커가 번들을 열어
/// 확정하기 전까지는 **어떤 앱인지 정해지지 않은 상태**다 (ADR-0034). 워커가
/// 실패하면 그 상태로 남고, 지금까지는 치울 방법이 없었다.
public enum PendingAppRemoval {
    /// 확정 전 앱 하나를 지운다.
    ///
    /// **확정된 앱은 지우지 않는다.** 그건 다른 결정이다. 번들 ID 가 정해졌다는 것은
    /// 누군가 설치했을 수 있다는 뜻이고, 다운로드 이력과 피드백이 매달려 있다.
    /// 여기서 지우는 것은 **한 번도 무엇인지 정해진 적 없는 행** 뿐이다.
    public static func remove(
        _ app: App,
        by user: User,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws {
        try app.requireManageAccess(for: user)

        guard app.bundleIDPending else {
            throw Abort(
                .conflict,
                reason: "확정된 앱은 지울 수 없습니다. 번들 ID 가 정해진 뒤에는 받아간 사람이 있을 수 있습니다."
            )
        }

        let appID = try app.requireID()
        let versions = try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .with(\.$artifacts)
            .all()

        // **스토리지를 먼저 치운다.** 행을 먼저 지우면 어떤 오브젝트가 남았는지
        // 알아낼 방법이 없어진다. 반대 순서로 실패하면 행이 남아서 다시 시도할 수 있다.
        for artifact in versions.flatMap(\.artifacts) {
            do {
                try await storage.delete(key: artifact.storageKey)
            } catch {
                // 오브젝트가 이미 없을 수도 있고 스토리지가 잠깐 맛이 갔을 수도 있다.
                // 둘 다 등록을 치우는 것을 막을 이유는 아니다. 남은 것은 로그로 쫓는다.
                logger.warning(
                    "확정 전 앱을 지우는 중 오브젝트를 치우지 못했습니다 [키: \(artifact.storageKey), 이유: \(error)]"
                )
            }
        }

        // `downloads` 는 버전을 cascade 없이 참조한다. 확정 전 앱은 출시된 적이 없어
        // 실제로는 비어 있지만, 비어 있다는 가정 위에 삭제를 세우지는 않는다.
        let versionIDs = try versions.map { try $0.requireID() }
        if !versionIDs.isEmpty {
            try await Download.query(on: database)
                .filter(\.$version.$id ~~ versionIDs)
                .delete()
        }

        // 나머지(버전, 아티팩트, 멤버, 토큰, 잡)는 외래 키 cascade 가 따라 지운다.
        try await app.delete(on: database)

        logger.notice(
            "확정 전 앱을 지웠습니다 [id: \(appID), 이름: \(app.name), 지운 사람: \(user.email)]"
        )
    }
}
