import AlleyShared
import Fluent
import Foundation
import Vapor

/// 스토어 앱을 로그인 없이 받는 자리 (ADR-0049).
///
/// **콘솔과 보는 사람이 다르다.** `/apps` 는 앱을 올리는 사람이 보는 화면이고,
/// 스토어 앱 안내는 그 화면 맨 위 한 줄로 얹혀 있었다. 그런데 스토어 앱이 필요한
/// 사람은 앱을 올리는 사람이 아니라 받는 사람이다. 사내 위키나 온보딩 문서에
/// 적어둘 주소가 필요한데, 콘솔 주소를 적으면 받으러 온 사람이 개발자용 화면에
/// 먼저 떨어진다.
///
/// **로그인을 요구하지 않는다.** 요구하면 순서가 막힌다. 로그인은 브라우저에서도
/// 되지만, 그렇게 세션을 만들어봐야 이 사람이 하려는 일은 앱을 받는 것 하나다.
/// 무엇이 새로 열리고 무엇이 그대로인지는 ADR-0049 에 적었다. 요약하면, 나가는
/// 것은 서명·공증된 바이너리 하나이고 그것만으로는 아무것도 볼 수 없다. 앱은
/// 자기 서버에 로그인해야 목록을 받는다 (ADR-0044).
///
/// 세션이 있으면 그 사람을 이력에 적는다. 없으면 익명으로 남긴다. 받아간 사실
/// 자체는 어느 쪽이든 남는다 (`Download`).
struct StoreAppGetController: RouteCollection, Sendable {
    /// 공개 페이지의 주소. 사람에게 알려줄 값이라 짧게 둔다.
    static let path = "get"

    func boot(routes: any RoutesBuilder) throws {
        // 세션이 있으면 사용자를 붙이되, 없다고 막지 않는다. 로그인 화면이 쓰는
        // 것과 같은 조합이다 (`WebController`).
        let open = routes.grouped(SessionAuthenticator()).grouped(PathComponent(stringLiteral: Self.path))

        open.get(use: page)
        open.get("download", use: download)
    }

    // MARK: - 화면

    @Sendable
    func page(request: Request) async throws -> View {
        let ready = try await Self.releasedStoreApp(on: request)

        return try await request.view.render(
            "get",
            StoreAppGetContext(
                page: try await request.pageContext(title: "스토어 앱 받기"),
                app: ready.map { found in
                    StoreAppGetRow(
                        name: found.app.name,
                        shortVersion: found.version.shortVersion,
                        buildNumber: found.version.buildNumber,
                        minimumSystemVersion: found.version.minimumOSVersion,
                        downloadPath: "/\(Self.path)/download"
                    )
                }
            )
        ).get()
    }

    // MARK: - 받기

    /// 파일을 내준다.
    ///
    /// 화면이 링크를 그리는 조건과 같아야 한다. 화면이 안 그린다고 경로까지 막히는
    /// 것은 아니라서, 여는 조건은 여기가 기준이다 (`AppPagesController.download`
    /// 와 같은 규칙).
    @Sendable
    func download(request: Request) async throws -> Response {
        guard let found = try await Self.releasedStoreApp(on: request) else {
            throw Abort(.notFound, reason: "아직 받을 수 있는 스토어 앱이 없습니다. 관리자에게 문의하세요.")
        }
        // **서명본이 아니면 내주지 않는다.** `bestArtifact` 는 서명본이 없으면 올린
        // 그대로를 준다. 콘솔에서는 올린 사람이 자기 빌드를 확인하는 자리라 그 폴백이
        // 맞지만, 여기는 아무것도 모르는 사람이 받는 자리다. 미서명 앱은 Gatekeeper
        // 가 막고, 막힌 사람은 "서명이 안 됐구나" 가 아니라 "앱이 깨졌구나" 라고
        // 생각한다 (ADR-0049).
        guard let artifact = Self.downloadable(found.version) else {
            throw Abort(
                .conflict,
                reason: "이 버전은 아직 서명되지 않았습니다. 서명이 끝난 뒤에 받을 수 있습니다."
            )
        }

        // URL 을 내주기 전에 남긴다. 나중에 남기면 URL 만 받고 이력이 빠지는 경로가
        // 생긴다. 로그인해 있으면 그 사람을, 아니면 익명으로 남긴다 (ADR-0049).
        let user = request.auth.get(User.self)
        try await Download(
            userID: try user?.requireID(),
            versionID: try found.version.requireID()
        ).save(on: request.db)

        let presigned = try await request.artifactStorage.downloadURL(
            key: artifact.storageKey,
            filename: Self.downloadFilename(app: found.app, version: found.version)
        )
        request.logger.notice(
            """
            공개 페이지에서 스토어 앱을 내려받습니다 \
            [\(found.app.bundleID) \(found.version.shortVersion) (\(found.version.buildNumber)), \
            받는 사람: \(user?.email ?? "로그인하지 않음")]
            """
        )
        return request.redirect(to: presigned.url)
    }

    // MARK: - 찾기

    struct FoundStoreApp {
        var app: App
        var version: Version
    }

    /// 지금 받을 수 있는 스토어 앱과 그 버전. 없으면 nil.
    ///
    /// **출시본만 내준다.** 서명·공증 전인 것을 여기로 내보내면 받은 사람의 맥이
    /// 열지 못한다. 그 사람은 앱이 깨졌다고 생각하지, 아직 안 나온 버전을 받았다고
    /// 생각하지 않는다.
    static func releasedStoreApp(on request: Request) async throws -> FoundStoreApp? {
        guard let appID = try await request.storeAppSettings().$app.id,
              let app = try await App.find(appID, on: request.db)
        else {
            return nil
        }
        // 화면이 링크를 그리는 조건과 받기 경로가 여는 조건이 같아야 한다. 한 곳에서
        // 고른다. 서명본이 없는 버전은 아예 후보가 아니다.
        let candidates = try await Version.query(on: request.db)
            .filter(\.$app.$id == appID)
            .filter(\.$state == .released)
            .with(\.$artifacts)
            .sort(\.$buildNumber, .descending)
            .all()

        guard let version = candidates.first(where: { downloadable($0) != nil }) else {
            return nil
        }
        return FoundStoreApp(app: app, version: version)
    }
}

extension StoreAppGetController {
    /// 이 버전에서 사람에게 내줄 파일.
    ///
    /// **미서명본으로는 내려가지 않는다.** `bestArtifact` 는 서명본이 없으면 올린
    /// 그대로를 주는데, 여기는 아무것도 모르는 사람이 받는 자리라 그 폴백이 맞지 않다.
    static func downloadable(_ version: Version) -> Artifact? {
        (version.$artifacts.value ?? []).first { $0.kind == .signed }
    }

    /// 받는 사람의 내려받기 폴더에 남을 이름.
    ///
    /// 오브젝트 키를 그대로 쓰면 `unsigned.zip` 이 된다. 무엇을 받았는지 알 수 없고,
    /// 두 번 받으면 `unsigned (2).zip` 이 된다. 앱 이름과 버전을 적어서 내보낸다.
    static func downloadFilename(app: App, version: Version) -> String {
        "\(app.name) \(version.shortVersion).zip"
    }
}

// MARK: - 화면에 넘기는 값

struct StoreAppGetContext: Encodable {
    var page: PageContext
    /// 받을 수 있는 스토어 앱. 아직 출시본이 없으면 nil 이다.
    var app: StoreAppGetRow?
}

struct StoreAppGetRow: Encodable {
    var name: String
    var shortVersion: String
    var buildNumber: Int
    var minimumSystemVersion: String?
    var downloadPath: String
}
