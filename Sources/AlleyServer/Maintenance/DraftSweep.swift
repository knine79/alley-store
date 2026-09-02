import AlleyShared
import Fluent
import Foundation
import Vapor

/// 업로드 통지 없이 버려진 `draft` 버전과 그 오브젝트를 지운다.
///
/// 버전을 만들면 자리(presigned URL)를 내주고 `draft` 로 둔다. 클라이언트가 올린 뒤
/// `complete` 를 불러야 `uploaded` 로 넘어간다. 브라우저를 닫거나 CI 가 중간에 죽으면
/// 그 통지가 오지 않고, 행과 오브젝트가 그대로 남는다. 아무도 보지 않는 수백 MB 가
/// 계속 쌓인다 (ADR-0009).
public enum DraftSweep {
    /// 확인 주기.
    ///
    /// 지우는 대상이 "며칠 된 것"이라 자주 볼 이유가 없다. 한 시간에 한 번이면
    /// 서버를 하루에도 몇 번 재배포하는 환경에서도 언젠가는 돈다.
    static let checkInterval: Duration = .seconds(3600)

    /// 이 버전이 버려진 `draft` 인지.
    ///
    /// 시각과 보관 기간을 인자로 받는 순수 함수로 둔다. "사흘 된 draft" 를
    /// 데이터베이스와 시계 없이 확인할 수 있어야 한다.
    static func isAbandoned(_ version: Version, now: Date, retention: TimeInterval) -> Bool {
        // draft 를 벗어난 버전은 누군가 완료를 알린 것이다. 여기서 손대지 않는다.
        guard version.state == .draft else { return false }
        // 시각을 모르면 판단하지 않는다. 지우는 쪽으로 기울면 안 되는 판단이다.
        guard let created = version.createdAt else { return false }
        return now.timeIntervalSince(created) > retention
    }

    /// 버려진 draft 를 한 번 훑는다.
    static func run(on application: Application, now: Date = Date()) async {
        let database = application.db
        let logger = application.logger
        let storage = application.artifactStorage
        let retention = application.alleyConfig.draftRetention

        let drafts = (try? await Version.query(on: database)
            .filter(\.$state == .draft)
            .all()) ?? []

        for version in drafts {
            guard isAbandoned(version, now: now, retention: retention) else { continue }
            guard let versionID = try? version.requireID() else { continue }

            let key = ArtifactStorage.objectKey(
                appID: version.$app.id,
                versionID: versionID,
                kind: version.uploadKind.artifactKind
            )

            // 행을 지우기 전에 스토리지를 먼저 본다. 순서가 중요하다. 행을 먼저 지우면
            // 오브젝트가 어느 키에 있는지 아는 유일한 근거가 사라져서, 스토리지 접근이
            // 실패했을 때 아무도 못 찾는 파일이 남는다.
            //
            // 여기서 파일이 없다고 나오는 것이 "아직 올리는 중"을 뜻하지는 않는다.
            // 올리는 자리를 여는 presigned URL 은 S3_PRESIGNED_URL_TTL(기본 1시간)
            // 뒤에 만료되고, 보관 기간은 그보다 훨씬 길다. 그 시간이 지나도록 파일이
            // 없으면 시작조차 하지 않은 업로드다.
            let uploaded: Int64?
            do {
                uploaded = try await storage.head(key: key)
            } catch {
                // 스토리지가 죽었을 뿐인데 행을 지우면 오브젝트가 고아가 된다.
                // 다음 주기에 다시 본다.
                logger.warning("버려진 draft 를 확인하지 못했습니다 [버전: \(versionID), 오류: \(error)]")
                continue
            }

            if let size = uploaded {
                do {
                    try await storage.delete(key: key)
                } catch {
                    logger.warning("draft 의 오브젝트를 지우지 못했습니다 [키: \(key), 오류: \(error)]")
                    continue
                }
                logger.notice(
                    "버려진 draft 의 오브젝트를 지웠습니다 [버전: \(version.shortVersion) (\(version.buildNumber)), \(size) 바이트]"
                )
            }

            do {
                try await version.delete(on: database)
            } catch {
                logger.warning("버려진 draft 를 지우지 못했습니다 [버전: \(versionID), 오류: \(error)]")
                continue
            }
            logger.notice(
                "버려진 draft 를 지웠습니다 [버전: \(version.shortVersion) (\(version.buildNumber))]"
            )
        }
    }
}
