import AlleyShared
import Fluent
import Foundation
import Vapor

/// 관리자 화면. 스토어 설정과 역할 관리.
///
/// 규칙은 `AdminOperations` 에 있고 JSON API 와 공유한다. 여기서는 폼에서 온 문자열을
/// 요청 타입으로 옮기는 일만 한다.
///
/// **워커 등록 화면은 아직 없다.** `workers` 표가 Phase 1-3 에서 생긴다.
struct AdminPagesController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        let pages = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped("admin")

        pages.get(use: home)
        pages.get("settings", use: settingsForm)
        pages.post("settings", use: submitSettings)
        pages.get("users", use: userList)
        pages.post("users", ":userID", "role", use: submitRole)
    }

    /// 관리 화면의 첫 장은 설정이다. 역할 관리는 사람이 들어올 때마다 하는 일이 아니다.
    @Sendable
    func home(request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        return request.redirect(to: "/admin/settings")
    }

    // MARK: - 스토어 설정

    @Sendable
    func settingsForm(request: Request) async throws -> View {
        _ = try request.requireAdmin()
        let settings = try await request.storeSettings()
        return try await renderSettings(
            StoreSettingsFormValues(settings: settings),
            error: nil,
            // 저장하고 나면 같은 화면으로 돌아온다. 아무 표시가 없으면 저장이 됐는지
            // 알 수 없어서, 리다이렉트에 붙여둔 표시를 읽어 한 줄 띄운다.
            saved: request.query[String.self, at: "saved"] == "1",
            on: request
        )
    }

    @Sendable
    func submitSettings(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let settings = try await request.storeSettings()
        let values = try request.content.decode(StoreSettingsFormValues.self)

        do {
            try await AdminOperations.updateSettings(
                values.toRequest(),
                of: settings,
                by: admin,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 사용자가 고칠 수 있는 실패다. 오류 화면으로 보내면 적은 값이 날아가고,
            // 무엇을 고쳐야 하는지도 폼에서 멀어진다. 보낸 값을 그대로 채워 다시 그린다.
            let view = try await renderSettings(
                values, error: abort.reason, saved: false, on: request
            )
            return htmlResponse(view, status: abort.status)
        }

        return request.redirect(to: "/admin/settings?saved=1")
    }

    private func renderSettings(
        _ values: StoreSettingsFormValues,
        error: String?,
        saved: Bool,
        on request: Request
    ) async throws -> View {
        try await request.view.render(
            "admin-settings",
            StoreSettingsPageContext(
                page: try await request.pageContext(title: "스토어 설정"),
                values: values,
                error: error,
                saved: saved
            )
        ).get()
    }

    // MARK: - 역할 관리

    @Sendable
    func userList(request: Request) async throws -> View {
        let admin = try request.requireAdmin()
        return try await renderUsers(error: nil, viewedBy: admin, on: request)
    }

    @Sendable
    func submitRole(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let target = try await request.findUser()
        let values = try request.content.decode(RoleFormValues.self)

        guard let role = UserRole(rawValue: values.role) else {
            throw Abort(.badRequest, reason: "알 수 없는 역할입니다: \(values.role)")
        }

        do {
            try await AdminOperations.changeRole(
                of: target,
                to: role,
                by: admin,
                on: request.db,
                logger: request.logger
            )
        } catch let abort as any AbortError where abort.status.code < 500 {
            // 마지막 관리자를 강등하려는 경우가 여기로 온다. 목록을 그대로 두고
            // 왜 안 되는지만 위에 띄운다.
            let view = try await renderUsers(error: abort.reason, viewedBy: admin, on: request)
            return htmlResponse(view, status: abort.status)
        }
        return request.redirect(to: "/admin/users")
    }

    private func renderUsers(
        error: String?,
        viewedBy admin: User,
        on request: Request
    ) async throws -> View {
        let users = try await User.query(on: request.db).sort(\.$email).all()
        let adminID = try admin.requireID()

        return try await request.view.render(
            "admin-users",
            UserListPageContext(
                page: try await request.pageContext(title: "역할 관리"),
                users: try users.map { user in
                    UserRow(user: user, isSelf: try user.requireID() == adminID)
                },
                roles: UserRole.allCases.map { RoleOption(value: $0.rawValue, name: $0.displayName) },
                error: error
            )
        ).get()
    }

    private func htmlResponse(_ view: View, status: HTTPStatus) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(buffer: view.data)
        return response
    }
}

// MARK: - 화면별 데이터

/// 설정 폼이 주고받는 값.
///
/// 전부 문자열인 이유는 HTML 폼이 그것밖에 못 보내기 때문이다. 허용 도메인은
/// 쉼표로 나눈 한 줄로 다룬다. 항목마다 칸을 만들어 추가·삭제 버튼을 다는 것은
/// 스크립트를 요구하는데, 도메인은 조직 하나에 보통 한두 개다.
struct StoreSettingsFormValues: Codable {
    var storeName: String?
    var logoURL: String?
    var accentColor: String?
    var allowedEmailDomains: String?
    var bundleIDPrefix: String?
    /// 체크박스는 꺼져 있으면 아예 전송되지 않는다. 그래서 옵셔널이고 nil 이 곧 꺼짐이다.
    var enforceBundleIDPrefix: String?
    var confirmOpenToAnyDomain: String?

    init(settings: StoreSettings) {
        self.storeName = settings.storeName
        self.logoURL = settings.logoURL
        self.accentColor = settings.accentColor
        self.allowedEmailDomains = settings.allowedEmailDomains.joined(separator: ", ")
        self.bundleIDPrefix = settings.bundleIDPrefix
        self.enforceBundleIDPrefix = settings.enforceBundleIDPrefix ? "on" : nil
        self.confirmOpenToAnyDomain = nil
    }

    func toRequest() -> UpdateStoreSettingsRequest {
        UpdateStoreSettingsRequest(
            storeName: storeName ?? "",
            logoURL: logoURL ?? "",
            accentColor: accentColor ?? "",
            allowedEmailDomains: (allowedEmailDomains ?? "").split(separator: ",").map(String.init),
            bundleIDPrefix: bundleIDPrefix ?? "",
            // 폼은 화면에 있는 모든 항목을 한 번에 보낸다. 체크가 없으면 껐다는 뜻이다.
            enforceBundleIDPrefix: enforceBundleIDPrefix != nil,
            confirmOpenToAnyDomain: confirmOpenToAnyDomain != nil
        )
    }
}

extension StoreSettingsFormValues: Content {}

struct StoreSettingsPageContext: Encodable {
    var page: PageContext
    var values: StoreSettingsFormValues
    var error: String?
    var saved: Bool
}

struct RoleFormValues: Codable {
    var role: String
}

extension RoleFormValues: Content {}

struct UserRow: Encodable {
    var id: String
    var email: String
    var name: String
    var role: String
    var roleName: String
    /// 자기 자신인지. 화면에서 표시만 하고 변경을 막지는 않는다.
    /// 마지막 관리자만 아니면 스스로 물러나는 것은 정당한 동작이다.
    var isSelf: Bool

    init(user: User, isSelf: Bool) {
        self.id = user.id?.uuidString ?? ""
        self.email = user.email
        self.name = user.name
        self.role = user.role.rawValue
        self.roleName = user.role.displayName
        self.isSelf = isSelf
    }
}

struct RoleOption: Encodable {
    var value: String
    var name: String
}

struct UserListPageContext: Encodable {
    var page: PageContext
    var users: [UserRow]
    var roles: [RoleOption]
    var error: String?
}
