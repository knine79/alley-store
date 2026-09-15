import AlleyShared
import Fluent
import Foundation
import Vapor

/// 운영 파이프라인이 쓰는 경로 (ADR-0043).
///
/// 운영 레포의 CI 가 제품을 빌드·서명한 뒤 여기로 올립니다.
///
/// **앱이 아닌 것들이 여기로 옵니다.** 워커 릴리스와 스토어 앱이 그렇습니다. 둘 다
/// 올릴 자리가 웹 폼밖에 없었고, 배포 토큰은 앱 하나에 묶이는 것이라 맞지 않습니다
/// (ADR-0015). 스토어 앱은 서버가 직접 빌드하므로 더더욱 앱 토큰을 쓸 이유가
/// 없습니다 (ADR-0046).
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

        // 스토어 앱. 베이스 번들을 올리고, 그것으로 새 버전을 빌드시킨다.
        //
        // 관리 화면이 하는 일과 같은 것을 CI 가 하는 자리다. 이것이 없으면 제품
        // 릴리스마다 사람이 파일을 올리고 버튼을 눌러야 하고, 그러면 자동 릴리스가
        // 사라진다.
        ops.on(
            .POST,
            "store-app", "base-bundle",
            body: .collect(maxSize: .init(value: StoreAppBuildService.maximumBaseBundleSize)),
            use: uploadStoreAppBaseBundle
        )
        ops.post("store-app", "build", use: buildStoreApp)
        ops.get("store-app", use: storeAppStatus)
    }

    // MARK: - 스토어 앱

    /// CI 가 만든 브랜딩 없는 번들을 올린다.
    @Sendable
    func uploadStoreAppBaseBundle(request: Request) async throws -> StoreAppStatusDTO {
        let token = try request.requireOperator()
        let settings = try await request.storeAppSettings()
        let form = try request.content.decode(UploadStoreAppBaseBundleRequest.self)

        guard let file = form.bundle, file.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "스토어 앱 번들 zip 이 없습니다.")
        }

        try await StoreAppBuildService.acceptBaseBundle(
            version: form.version,
            data: Data(buffer: file.data),
            settings: settings,
            by: token.createdBy,
            storage: request.application.artifactStorage,
            on: request.db,
            logger: request.logger
        )
        request.logger.notice(
            "운영 토큰으로 스토어 앱 베이스 번들을 올렸습니다 [버전: \(form.version), 토큰: \(token.name)]"
        )
        return try await Self.status(settings: settings, on: request)
    }

    /// 지금 설정으로 새 버전을 빌드한다.
    ///
    /// **출시하지는 않습니다.** 서명·공증이 끝나야 출시할 수 있고, 그 판단은 사람이
    /// 합니다. 다른 앱과 같은 규칙입니다. 예전 `alley upload` 경로도 여기까지만
    /// 했습니다.
    @Sendable
    func buildStoreApp(request: Request) async throws -> Response {
        let token = try request.requireOperator()
        let settings = try await request.storeAppSettings()

        let icon = try await StoreAppBuildService.appIcon(on: request)
        let result = try await StoreAppBuildService.build(
            settings: settings,
            icon: icon,
            serverURL: request.application.alleyConfig.publicBaseURL,
            by: token.createdBy,
            storage: request.application.artifactStorage,
            on: request.db,
            logger: request.logger
        )
        request.logger.notice(
            "운영 토큰으로 스토어 앱을 빌드했습니다 [\(result.shortVersion) (\(result.buildNumber)), 토큰: \(token.name)]"
        )

        let response = Response(status: .created)
        try response.content.encode(try await Self.status(settings: settings, on: request))
        return response
    }

    /// 지금 무엇이 올라가 있는지. CI 가 "이미 했나" 를 확인한다.
    ///
    /// 같은 빌드를 두 번 만들면 버전이 하나 더 늘어난다. 워커 릴리스와 달리 서버가
    /// 막아주지 않으므로(빌드 번호를 스스로 올린다) CI 가 먼저 물어봐야 한다.
    @Sendable
    func storeAppStatus(request: Request) async throws -> StoreAppStatusDTO {
        _ = try request.requireOperator()
        return try await Self.status(settings: try await request.storeAppSettings(), on: request)
    }

    private static func status(
        settings: StoreAppSettings,
        on request: Request
    ) async throws -> StoreAppStatusDTO {
        var builds: [StoreAppStatusDTO.Build] = []
        if let appID = settings.$app.id {
            builds = try await Version.query(on: request.db)
                .filter(\.$app.$id == appID)
                .sort(\.$buildNumber, .descending)
                .limit(20)
                .all()
                .map {
                    StoreAppStatusDTO.Build(
                        shortVersion: $0.shortVersion,
                        buildNumber: $0.buildNumber,
                        state: $0.state.rawValue
                    )
                }
        }
        return StoreAppStatusDTO(
            bundleID: settings.bundleID,
            appName: settings.appName,
            baseBundleVersion: settings.baseBundleVersion,
            builds: builds
        )
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

/// 운영 파이프라인이 올리는 스토어 앱 베이스 번들.
struct UploadStoreAppBaseBundleRequest: Content {
    /// 이 번들이 담고 있는 제품 버전. `CFBundleShortVersionString` 이 된다.
    var version: String
    /// 브랜딩 없는 미서명 번들 zip.
    var bundle: File?
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
