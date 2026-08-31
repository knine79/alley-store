import AlleyShared
import Fluent
import Foundation
import Vapor

/// 버전 업로드 화면과 출시·철회 버튼.
///
/// **업로드만 브라우저에서 JSON API 를 부른다.** 나머지 화면은 폼을 서버가 받지만,
/// 업로드는 바이너리가 서버를 거치지 않고 스토리지로 직접 가야 해서(ADR-0009)
/// 브라우저가 세 단계를 직접 밟는다. 자세한 이유는 ADR-0012 에 있다.
///
/// 출시와 철회는 폼 하나짜리 `POST` 다. 스크립트를 쓸 이유가 없다.
struct VersionPagesController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("apps", ":appID", "versions")

        pages.get("new", use: newForm)
        pages.post(":versionID", "release", use: release)
        pages.post(":versionID", "unrelease", use: unrelease)
        pages.post(":versionID", "retry", use: retry)
    }

    // MARK: - 업로드 화면

    @Sendable
    func newForm(request: Request) async throws -> View {
        let user = try request.requireUser()
        let app = try await request.findApp()
        try await app.requireUploadAccess(for: user, on: request.db)

        let appID = try app.requireID()
        return try await request.view.render(
            "version-new",
            VersionFormContext(
                page: try await request.pageContext(title: "새 버전"),
                appID: appID.uuidString,
                appName: app.name,
                // 다음 빌드 번호를 미리 채워준다. 같은 번호를 쓰면 서버가 거절하는데,
                // 마지막 번호가 몇이었는지 확인하러 목록으로 돌아가게 할 이유가 없다.
                suggestedBuildNumber: try await nextBuildNumber(ofApp: appID, on: request.db),
                createVersionPath: APIPath.versions(ofApp: appID),
                versionRootPath: "\(APIPath.apiRoot)/versions"
            )
        ).get()
    }

    private func nextBuildNumber(ofApp appID: UUID, on database: any Database) async throws -> Int {
        let highest = try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .sort(\.$buildNumber, .descending)
            .first()
        return (highest?.buildNumber ?? 0) + 1
    }

    // MARK: - 출시 / 철회

    @Sendable
    func release(request: Request) async throws -> Response {
        try await changeRelease(on: request) { try $0.transition(to: .released) }
    }

    /// 출시 철회. 배포 가능하지만 비공개인 `ready` 로 돌아간다.
    ///
    /// 아티팩트는 지우지 않는다. 이미 받아간 사람의 앱은 계속 동작하고,
    /// 문제가 해결되면 다시 출시할 수 있어야 한다.
    @Sendable
    func unrelease(request: Request) async throws -> Response {
        try await changeRelease(on: request) { version in
            try version.transition(to: .ready)
            version.releasedAt = nil
        }
    }

    // MARK: - 재시도

    /// 실패한 버전을 다시 서명 큐에 넣는다.
    ///
    /// 올린 바이너리는 그대로 두고 상태만 되돌린다. 서명이 실패하는 이유는 대개 워커
    /// 쪽 환경(인증서 만료, 공증 자격증명)이라, 고친 뒤 같은 파일로 다시 시도하는 것이
    /// 자연스럽다. 파일 자체가 문제였다면 새 빌드를 올리면 된다.
    @Sendable
    func retry(request: Request) async throws -> Response {
        let user = try request.requireUser()
        let version = try await request.findVersion()
        try await version.app.requireUploadAccess(for: user, on: request.db)

        guard let appID = request.parameters.get("appID", as: UUID.self),
              version.$app.id == appID
        else {
            throw Abort(.notFound, reason: "버전을 찾을 수 없습니다.")
        }
        guard version.state == .failed else {
            throw Abort(
                .conflict,
                reason: "실패한 버전만 다시 시도할 수 있습니다. 현재 상태: \(version.state.rawValue)"
            )
        }

        try version.transition(to: .uploaded)
        // 완성본을 올린 경로에는 워커가 할 일이 없다. 상태만 제자리로 돌린다.
        if version.uploadKind == .signed {
            try version.transition(to: .ready)
        }
        try await version.save(on: request.db)

        if version.uploadKind == .unsigned {
            try await SigningJob.enqueue(versionID: try version.requireID(), on: request.db)
        }
        return request.redirect(to: "/apps/\(appID.uuidString)")
    }

    private func changeRelease(
        on request: Request,
        apply: (Version) throws -> Void
    ) async throws -> Response {
        let user = try request.requireUser()
        let version = try await request.findVersion()
        try await version.app.requireUploadAccess(for: user, on: request.db)

        // 주소의 앱과 버전이 실제로 이어져 있는지 확인한다. 권한은 버전이 속한 앱으로
        // 확인했으므로 이것이 없어도 뚫리지는 않지만, 그러면 남의 앱 주소로 내 버전을
        // 출시한 뒤 엉뚱한 화면으로 돌아가게 된다.
        guard let appID = request.parameters.get("appID", as: UUID.self),
              version.$app.id == appID
        else {
            throw Abort(.notFound, reason: "버전을 찾을 수 없습니다.")
        }

        try apply(version)
        try await version.save(on: request.db)
        return request.redirect(to: "/apps/\(appID.uuidString)")
    }
}

// MARK: - 화면별 데이터

struct VersionFormContext: Encodable {
    var page: PageContext
    var appID: String
    var appName: String
    var suggestedBuildNumber: Int
    /// 스크립트가 버전을 만들 때 부를 경로.
    var createVersionPath: String
    /// 만든 버전의 완료 통지 경로를 조립할 뿌리. `<root>/<id>/complete` 가 된다.
    var versionRootPath: String
}
