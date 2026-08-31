import AlleyShared
import Fluent
import Foundation
import Vapor

/// 개발자 포털 현황을 보여주는 관리자 경로.
///
/// 여기서 하는 일은 **보는 것과 등록하는 것**뿐이다. 인증서를 발급하거나 폐기하지
/// 않는다. 그건 사람이 Apple 의 화면에서 하는 일이고, 개인키는 이 서버에 오면 안 된다.
///
/// 연동이 설정되지 않았으면 그 사실을 그대로 알린다. 조용히 빈 목록을 주면
/// "인증서가 없다"와 "물어볼 수 없다"가 구분되지 않는다.
public struct PortalController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let admin = routes
            .grouped(SessionAuthenticator(), User.guardMiddleware())
            .grouped(APIPath.adminRoot.pathComponents)
            .grouped("portal")

        admin.get("certificates", use: certificates)
        admin.get("bundle-ids", use: bundleIDs)
        admin.post("bundle-ids", use: registerBundleID)
    }

    @Sendable
    func certificates(request: Request) async throws -> [ASCCertificate] {
        _ = try request.requireAdmin()
        return try await request.appStoreConnect().certificates()
    }

    @Sendable
    func bundleIDs(request: Request) async throws -> [ASCBundleID] {
        _ = try request.requireAdmin()
        return try await request.appStoreConnect().bundleIDs()
    }

    @Sendable
    func registerBundleID(request: Request) async throws -> Response {
        let admin = try request.requireAdmin()
        let payload = try request.content.decode(RegisterBundleIDRequest.self)
        let registered = try await PortalRegistration.registerBundleID(
            payload,
            using: try request.appStoreConnect(),
            by: admin,
            logger: request.logger
        )

        let response = Response(status: .created)
        try response.content.encode(registered)
        return response
    }
}

/// App ID 등록의 실제 규칙.
enum PortalRegistration {
    static func registerBundleID(
        _ payload: RegisterBundleIDRequest,
        using client: AppStoreConnectClient,
        by admin: User,
        logger: Logger
    ) async throws -> ASCBundleID {
        let identifier = payload.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !identifier.isEmpty else {
            throw Abort(.badRequest, reason: "App ID 가 비어 있습니다.")
        }
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "이름이 비어 있습니다. 포털 목록에서 알아볼 이름을 적으세요.")
        }
        // Apple 은 와일드카드를 끝에서만 받는다. 여기서 걸러야 왕복 한 번을 아낀다.
        if identifier.contains("*"), !identifier.hasSuffix(".*") {
            throw Abort(
                .badRequest,
                reason: "와일드카드는 맨 끝에만 올 수 있습니다. 예: com.example.*"
            )
        }

        // 이미 있는 것을 또 만들면 Apple 이 거절한다. 그 전에 우리가 답한다.
        let existing = try await client.bundleIDs()
        if let found = existing.first(where: { $0.identifier == identifier }) {
            throw Abort(.conflict, reason: "'\(found.identifier)' 는 이미 포털에 등록돼 있습니다.")
        }

        let registered = try await client.registerBundleID(identifier: identifier, name: name)
        logger.notice("App ID 등록 [\(registered.identifier), 관리자: \(admin.email)]")
        return registered
    }
}

extension Request {
    /// 설정된 App Store Connect 클라이언트.
    ///
    /// 설정이 없으면 여기서 막는다. 이 서버의 다른 기능은 이것 없이도 전부 동작하므로
    /// 부팅을 막지는 않고, 이 경로만 닫는다.
    func appStoreConnect() throws -> AppStoreConnectClient {
        guard let config = application.alleyConfig.appStoreConnect else {
            throw Abort(
                .serviceUnavailable,
                reason: AppStoreConnectClient.ClientError.notConfigured.description
            )
        }
        return AppStoreConnectClient(config: config, client: client)
    }
}

extension ASCCertificate: Content {}
extension ASCBundleID: Content {}
extension RegisterBundleIDRequest: Content {}
