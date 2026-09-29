import AlleyShared
import Crypto
import Fluent
import Foundation
import Vapor

/// 운영 CI 가 올린 `alley` 바이너리를 받아 보관한다 (ADR-0065).
///
/// `WorkerReleaseService` 와 같은 모양이다. 다른 것은 받는 것이 zip 이 아니라
/// **맨 실행 파일**이라는 것뿐이다.
enum CLIReleaseService {
    /// Mach-O universal 바이너리의 첫 네 바이트 (`0xCAFEBABE`, big endian).
    ///
    /// 두 아키텍처를 함께 담은 것만 받는다. 한쪽만 담긴 것을 올리면 다른 칩을 쓰는
    /// 사람이 받아서 "실행할 수 없습니다" 를 본다. 그 사실이 받는 사람 맥에서야
    /// 드러나면 아무도 올린 쪽을 의심하지 않는다.
    static let universalMagic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]

    static func accept(
        version rawVersion: String,
        data: Data,
        makeCurrent: Bool,
        by uploader: User?,
        storage: any ArtifactStoring,
        on database: any Database,
        logger: Logger
    ) async throws -> CLIRelease {
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw Abort(.badRequest, reason: "버전이 없습니다.")
        }
        guard !data.isEmpty else {
            throw Abort(.badRequest, reason: "빈 파일입니다.")
        }
        guard data.starts(with: universalMagic) else {
            throw Abort(
                .badRequest,
                reason: """
                    universal 바이너리가 아닙니다. \
                    ./scripts/build-cli.sh --sign 이 만든 파일을 올려주세요.
                    """
            )
        }
        if try await CLIRelease.query(on: database).filter(\.$version == version).first() != nil {
            throw Abort(
                .conflict,
                reason: "버전 \(version) 은 이미 올려져 있습니다."
            )
        }

        let release = CLIRelease(
            version: version,
            storageKey: "",
            fileSize: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            uploadedByID: try uploader?.requireID()
        )
        try await release.save(on: database)

        // 키에 id 가 들어가야 해서 저장한 뒤에 정한다.
        let key = storage.newKey(CLIRelease.objectKey(releaseID: try release.requireID()))
        do {
            try await storage.put(data, to: key, contentType: "application/octet-stream")
        } catch {
            // 오브젝트가 없는 행을 남기면 받는 사람이 404 나는 주소를 받는다.
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
            CLI 릴리스를 받았습니다 [버전: \(version), \(data.count) 바이트, \
            배포: \(makeCurrent), 올린 사람: \(uploader?.email ?? "운영 토큰")]
            """
        )
        return release
    }

    /// 이 릴리스를 지금 내줄 것으로 만든다. 나머지는 내린다.
    ///
    /// 되돌릴 때도 이것을 쓴다. 새 CLI 에 문제가 있으면 옛 릴리스를 다시 현재로
    /// 만들면 되고, 그다음 받는 사람부터 그것을 받는다.
    static func makeCurrent(_ release: CLIRelease, on database: any Database) async throws {
        let releaseID = try release.requireID()
        try await database.transaction { db in
            try await CLIRelease.query(on: db)
                .filter(\.$isCurrent == true)
                .filter(\.$id != releaseID)
                .set(\.$isCurrent, to: false)
                .update()
            release.isCurrent = true
            try await release.save(on: db)
        }
    }
}
