import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// 관리자가 올린 워커 번들을 받아 보관한다 (ADR-0042).
///
/// **여기가 사람이 끼어드는 유일한 자리다.** 워커가 자기 다음 버전을 서명하므로,
/// 잘못된 빌드를 되돌릴 워커도 그 빌드가 된다. 그래서 "새 워커를 배포한다" 는
/// 판단만은 자동으로 두지 않는다.
public enum WorkerReleaseService {
    /// 워커 번들 zip 하나를 받는다.
    ///
    /// - Parameters:
    ///   - version: 올리는 사람이 적은 버전. 번들 안의 값과 맞춰야 한다.
    ///   - data: 번들을 담은 zip 원문.
    ///   - makeCurrent: 올리자마자 배포할지. 끄면 보관만 한다.
    @discardableResult
    public static func accept(
        version rawVersion: String,
        data: Data,
        makeCurrent: Bool,
        by admin: User,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws -> WorkerRelease {
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        // 견줄 수 없는 버전은 받지 않는다. 워커가 자기 것과 비교해서 판단하는데,
        // 읽을 수 없는 값이면 그 비교가 조용히 "낡지 않았다" 로 떨어진다.
        guard WorkerVersion.parts(of: version) != nil else {
            throw Abort(
                .badRequest,
                reason: "버전은 1.2.3 처럼 점으로 나눈 숫자여야 합니다. 받은 값: '\(version)'"
            )
        }
        guard !data.isEmpty else {
            throw Abort(.badRequest, reason: "빈 파일입니다.")
        }
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            throw Abort(
                .badRequest,
                reason: "zip 이 아닙니다. ./scripts/build-worker-app.sh --sign 이 만든 zip 을 올려주세요."
            )
        }
        // **정말 워커 번들인지 여기서 본다.** 설치 키트를 잘못 올리는 일이 흔하고,
        // 그것도 zip 이라 예전에는 그냥 통과했다. 잘못됐다는 사실이 10분 뒤 워커
        // 로그에만 남으면 아무도 못 알아본다.
        try WorkerBundleInspection.requireTopLevelApp(in: data)
        if try await WorkerRelease.query(on: database).filter(\.$version == version).first() != nil {
            throw Abort(
                .conflict,
                reason: "버전 \(version) 은 이미 올려져 있습니다. 워커의 버전을 올려 다시 빌드하세요."
            )
        }

        let release = WorkerRelease(
            version: version,
            storageKey: "",
            fileSize: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            uploadedByID: try admin.requireID()
        )
        try await release.save(on: database)

        // 키에 id 가 들어가야 해서 저장한 뒤에 정한다.
        let key = storage.newKey(WorkerRelease.objectKey(releaseID: try release.requireID()))
        do {
            try await storage.put(data, to: key, contentType: "application/zip")
        } catch {
            // 오브젝트가 없는 행을 남기면 워커가 404 나는 주소를 받는다.
            try? await release.delete(on: database)
            throw error
        }
        release.storageKey = key
        try await release.save(on: database)

        if makeCurrent {
            try await Self.makeCurrent(release, on: database)
        }
        logger.notice(
            """
            워커 릴리스를 받았습니다 [버전: \(version), \(data.count) 바이트, \
            배포: \(makeCurrent), 올린 사람: \(admin.email)]
            """
        )
        return release
    }

    /// 이 릴리스를 지금 배포할 것으로 만든다. 나머지는 내린다.
    ///
    /// 되돌릴 때도 이것을 쓴다. 새 워커에 문제가 있으면 옛 릴리스를 다시 현재로
    /// 만들면 되고, 워커들이 다음 확인에서 그쪽으로 내려간다.
    public static func makeCurrent(
        _ release: WorkerRelease,
        on database: any Database
    ) async throws {
        let releaseID = try release.requireID()
        try await WorkerRelease.query(on: database)
            .filter(\.$isCurrent == true)
            .filter(\.$id != releaseID)
            .set(\.$isCurrent, to: false)
            .update()
        release.isCurrent = true
        try await release.save(on: database)
    }

    /// 릴리스를 지운다. 배포 중인 것은 못 지운다.
    public static func remove(
        _ release: WorkerRelease,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws {
        guard !release.isCurrent else {
            throw Abort(
                .conflict,
                reason: "배포 중인 릴리스는 지울 수 없습니다. 다른 릴리스를 먼저 배포하세요."
            )
        }
        if !release.storageKey.isEmpty {
            do {
                try await storage.delete(key: release.storageKey)
            } catch {
                logger.warning(
                    "워커 릴리스의 오브젝트를 치우지 못했습니다 [키: \(release.storageKey), 이유: \(error)]"
                )
            }
        }
        try await release.delete(on: database)
    }
}
