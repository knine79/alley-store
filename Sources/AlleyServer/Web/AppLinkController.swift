import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 하나를 사람에게 건네는 공유 페이지 (ADR-0072).
///
/// 콘솔의 앱 상세(`/apps/:id`)는 그 앱을 손댈 수 있는 사람만 들어간다. 슬랙에 붙일
/// 주소는 받는 사람이 눌러서 바로 받는 주소여야 한다. 이 페이지가 그 자리다.
///
/// **스토어 앱을 커스텀 스킴으로 부른다.** 유니버설 링크는 프로비저닝 프로필이
/// 있어야 붙는데, 스토어 앱은 Developer ID 로 서명하고 프로필 없이 나간다. 페이지가
/// 열리면 스크립트가 `<scheme>://apps/<앱 ID>` 를 바로 부르고, 열리지 않은 것 같으면
/// 그때 버튼을 꺼낸다 (`Public/app-link.js`). 브라우저는 앱이 깔려 있는지 알려주지 않는다.
///
/// **로그인을 요구하지 않는다.** 웹으로 로그인하면 개발자가 된다 (ADR-0056). 받으러 온
/// 사람을 거기로 보내면 안 된다. 대신 **출시된 앱만** 보여준다. 출시 전 앱과 없는 앱은
/// 같은 404 화면이라 주소로 앱이 있는지 떠볼 수 없다 (ADR-0051).
struct AppLinkController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        // 세션이 있으면 머리에 그 사람을 그리되, 없다고 막지 않는다 (`/get` 과 같다).
        routes.grouped(SessionAuthenticator())
            .get(PathComponent(stringLiteral: AppLink.webPathComponent), ":appID", use: page)
    }

    @Sendable
    func page(request: Request) async throws -> Response {
        let settings = try await request.storeAppSettings()
        // 앱 ID 형식이 틀린 것도 같은 404 다. 400 으로 따로 답하면 "그런 앱은 없다" 와
        // "주소가 틀렸다" 가 구별되는데, 받는 사람에게 그 차이는 쓸모가 없다.
        guard let appID = request.parameters.get("appID", as: UUID.self) else {
            return try await notFound(on: request)
        }
        // 스토어 앱 자신은 목록에 없어서 스토어 앱에서 열 상세가 없다. 받는 자리로 보낸다.
        if settings.$app.id == appID {
            return request.redirect(to: "/\(StoreAppGetController.path)")
        }
        guard let app = try await App.find(appID, on: request.db),
              try await App.latestReleasedVersion(ofApp: appID, on: request.db) != nil
        else {
            return try await notFound(on: request)
        }

        let base = request.application.alleyConfig.publicBaseURL
        let context = AppLinkContext(
            page: try await request.pageContext(title: app.name),
            app: AppLinkRow(
                name: app.name,
                summary: app.summary,
                iconURL: app.iconURL,
                absoluteIconURL: App.absolute(app.iconURL, base: base),
                shareURL: App.absolute(AppLink.webPath(appID: appID), base: base) ?? "",
                openURL: AppLink.storeAppURL(scheme: settings.urlScheme, appID: appID)?.absoluteString,
                storeAppName: settings.appName,
                getPath: "/\(StoreAppGetController.path)"
            )
        )
        let view = try await request.view.render("app-link", context).get()
        return htmlResponse(view, status: .ok)
    }

    /// 없는 앱과 출시 전 앱이 같이 쓰는 화면. 둘을 구별할 단서를 남기지 않는다.
    private func notFound(on request: Request) async throws -> Response {
        let context = AppLinkContext(
            page: try await request.pageContext(title: "앱을 찾을 수 없습니다"),
            app: nil
        )
        let view = try await request.view.render("app-link", context).get()
        return htmlResponse(view, status: .notFound)
    }
}

// MARK: - 화면에 넘기는 값

struct AppLinkContext: Encodable {
    var page: PageContext
    /// 보여줄 앱. 없거나 출시 전이면 nil 이다.
    var app: AppLinkRow?
}

struct AppLinkRow: Encodable {
    var name: String
    var summary: String?
    /// 화면의 `img` 가 쓴다. 같은 출처라 상대 주소로 충분하다.
    var iconURL: String?
    /// 미리보기(`og:image`)가 쓴다. 페이지를 읽는 쪽은 브라우저가 아니라서 절대 주소여야 한다.
    var absoluteIconURL: String?
    var shareURL: String
    /// 스토어 앱을 부르는 주소. 스킴을 URL 로 만들 수 없으면 nil 이다.
    var openURL: String?
    /// 버튼에 적는 스토어 앱 이름. 조직이 정한다 (`StoreAppSettings.appName`).
    var storeAppName: String
    var getPath: String
}
