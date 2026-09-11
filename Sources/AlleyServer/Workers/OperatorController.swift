import AlleyShared
import Fluent
import Foundation
import Vapor

/// 운영 파이프라인이 쓰는 경로 (ADR-0043).
///
/// 운영 레포의 CI 가 제품을 빌드·서명한 뒤 여기로 올립니다. 스토어 앱은 앱이라
/// 기존 배포 토큰과 `alley upload` 로 올라가지만, 워커 릴리스는 앱이 아니어서
/// 올릴 자리가 웹 폼밖에 없었습니다.
public struct OperatorController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let ops = routes
            .grouped(OperatorAuthenticator())
            .grouped(APIPath.operatorRoot.pathComponents)

        ops.on(
            .POST,
            "worker-releases",
            // 워커 번들은 수 MB 다. 기본 상한(16KB)으로는 들어오지도 못한다.
            // presigned 로 우회하지 않는 이유는 ADR-0016 의 선례와 같다 - 이 하나
            // 때문에 세 단계를 또 만들 이유가 없다.
            body: .collect(maxSize: "64mb"),
            use: uploadWorkerRelease
        )
        ops.get("worker-releases", use: listWorkerReleases)
    }

    /// 워커 릴리스를 올린다.
    ///
    /// **올리는 것이 곧 배포입니다** (ADR-0042). 운영 레포의 CI 가 여기까지 오는
    /// 것은 사람이 PR 을 머지했다는 뜻이고, 그 머지가 승인입니다.
    @Sendable
    func uploadWorkerRelease(request: Request) async throws -> Response {
        let token = try request.requireOperator()
        let form = try request.content.decode(UploadWorkerReleaseRequest.self)

        guard let file = form.bundle, file.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "워커 번들 zip 이 없습니다.")
        }

        let release = try await WorkerReleaseService.accept(
            version: form.version,
            data: Data(buffer: file.data),
            // 끄고 올릴 수도 있게 둔다. 릴리스를 만들어두고 배포 시점을 따로 잡는
            // 운영 방식이 있다.
            makeCurrent: form.makeCurrent ?? true,
            by: token.createdBy,
            storage: request.application.artifactStorage,
            on: request.db,
            logger: request.logger
        )

        request.logger.notice(
            "운영 토큰으로 워커 릴리스를 올렸습니다 [버전: \(release.version), 토큰: \(token.name)]"
        )
        let response = Response(status: .created)
        try response.content.encode(try release.toDTO())
        return response
    }

    /// 올려둔 릴리스 목록. CI 가 "이미 올렸나" 를 확인한다.
    ///
    /// 같은 버전을 두 번 올리면 409 가 나는데, 재실행되는 파이프라인에서는 그것이
    /// 실패가 아니라 "이미 됐다" 다. 미리 볼 수 있어야 구분할 수 있다.
    @Sendable
    func listWorkerReleases(request: Request) async throws -> [WorkerReleaseSummaryDTO] {
        _ = try request.requireOperator()
        return try await WorkerRelease.query(on: request.db)
            .sort(\.$createdAt, .descending)
            .all()
            .map { try $0.toDTO() }
    }
}

/// 운영 파이프라인이 올리는 워커 릴리스.
///
/// `AlleyShared` 에 두지 않는다. `File` 이 Vapor 타입이고, 공유 모듈은 의존성을
/// 두지 않아 SwiftUI 앱에서도 그대로 임포트할 수 있어야 한다.
struct UploadWorkerReleaseRequest: Content {
    var version: String
    /// 번들 zip. 최상위에 `.app` 이 있어야 한다.
    var bundle: File?
    /// 올리자마자 배포할지. 기본은 배포한다.
    var makeCurrent: Bool?
}

extension WorkerRelease {
    func toDTO() throws -> WorkerReleaseSummaryDTO {
        WorkerReleaseSummaryDTO(
            id: try requireID(),
            version: version,
            fileSize: fileSize,
            sha256: sha256,
            isCurrent: isCurrent,
            createdAt: createdAt ?? Date()
        )
    }
}

extension WorkerReleaseSummaryDTO: Content {}
