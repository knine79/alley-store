import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 하나에 대해 누가 무엇을 할 수 있는가.
///
/// 역할(`UserRole`)은 "앱을 등록할 수 있는 사람인가"까지만 답한다. 남의 앱에
/// 버전을 올리는 것은 다른 질문이라 앱 단위 멤버십으로 한 번 더 좁힌다.
/// 조직 구성원 전체가 설치하게 될 바이너리이기 때문이다.
extension App {
    /// 메타데이터 수정과 멤버 관리. 오너와 관리자만.
    public func requireManageAccess(for user: User) throws {
        guard try canManage(user) else {
            throw Abort(.forbidden, reason: "이 앱을 관리할 권한이 없습니다. 앱 오너나 관리자에게 요청하세요.")
        }
    }

    public func canManage(_ user: User) throws -> Bool {
        if user.role.canAdminister { return true }
        return try $owner.id == user.requireID()
    }

    /// 버전 업로드와 출시. 오너, 관리자, 앱 멤버.
    ///
    /// 출시를 업로드와 같은 등급으로 두는 이유는, 바이너리를 올릴 수 있는 사람은
    /// 이미 그 앱의 내용을 정하는 사람이기 때문이다. 여기서 나누면 실제로는
    /// 오너가 매번 출시 버튼만 눌러주는 병목이 된다.
    public func requireUploadAccess(for user: User, on database: any Database) async throws {
        guard try await canUpload(user, on: database) else {
            throw Abort(.forbidden, reason: "이 앱에 버전을 올릴 권한이 없습니다. 앱 오너에게 멤버 추가를 요청하세요.")
        }
    }

    public func canUpload(_ user: User, on database: any Database) async throws -> Bool {
        if try canManage(user) { return true }
        let userID = try user.requireID()
        return try await AppMember.query(on: database)
            .filter(\.$app.$id == requireID())
            .filter(\.$user.$id == userID)
            .first() != nil
    }
}

/// 목록에서 "출시 전인 앱을 이 사람에게 보여도 되는가" 를 판정한다.
///
/// **출시된 앱은 모두에게 보인다.** 그것이 스토어의 뜻이다. 문제는 아직 출시하지
/// 않은 앱인데, 예전에는 "올릴 수 있는 사람(개발자·관리자)이면 전부" 보여줬다.
/// 그러면 개발자 한 사람이 다른 팀이 준비 중인 앱을 이름·번들 ID·설명까지 다 본다.
/// 아직 안 알린 것을 목록에서 먼저 보게 되는 자리다.
///
/// 손댈 수 있는 사람에게만 보인다. 오너, 앱 멤버, 관리자다. 업로드 권한과 같은
/// 기준이라 "보이는데 못 만지는" 상태가 생기지 않는다.
///
/// 앱마다 따로 물으면 N+1 이 된다. 멤버십을 한 번에 읽어두고 집합으로 견준다.
struct AppVisibility {
    private let isAdmin: Bool
    private let userID: UUID
    private let memberAppIDs: Set<UUID>

    static func of(_ user: User, on database: any Database) async throws -> AppVisibility {
        let userID = try user.requireID()
        let isAdmin = user.role.canAdminister

        // 관리자는 전부 보므로 멤버십을 읽을 이유가 없다.
        let memberships: [AppMember] = isAdmin
            ? []
            : try await AppMember.query(on: database).filter(\.$user.$id == userID).all()

        return AppVisibility(
            isAdmin: isAdmin,
            userID: userID,
            memberAppIDs: Set(memberships.map { $0.$app.id })
        )
    }

    func canSeeUnreleased(_ app: App) throws -> Bool {
        if isAdmin { return true }
        if app.$owner.id == userID { return true }
        return memberAppIDs.contains(try app.requireID())
    }
}

extension Request {
    /// 경로 파라미터의 앱을 찾는다. 없으면 404.
    func findApp() async throws -> App {
        guard let id = parameters.get("appID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "앱 ID 형식이 올바르지 않습니다.")
        }
        guard let app = try await App.find(id, on: db) else {
            throw Abort(.notFound, reason: "앱을 찾을 수 없습니다.")
        }
        return app
    }

    /// 경로 파라미터의 버전을 찾는다. 앱과 아티팩트를 함께 읽는다.
    ///
    /// 버전을 다루는 요청은 거의 전부 앱의 권한을 확인해야 하고 응답에 크기·해시가
    /// 필요해서, 매번 따로 읽지 않도록 여기서 한 번에 채운다.
    func findVersion() async throws -> Version {
        guard let id = parameters.get("versionID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "버전 ID 형식이 올바르지 않습니다.")
        }
        guard let version = try await Version.query(on: db)
            .filter(\.$id == id)
            .with(\.$app)
            .with(\.$artifacts)
            .first()
        else {
            throw Abort(.notFound, reason: "버전을 찾을 수 없습니다.")
        }
        return version
    }
}
