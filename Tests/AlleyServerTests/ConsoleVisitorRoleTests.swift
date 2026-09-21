import AlleyShared
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 웹 콘솔로 들어온 사람은 스스로 개발자가 된다 (ADR-0056).
///
/// 로그인 왕복은 테스트에서 재현할 수 없으므로 승격 판정만 직접 부른다. 그 판정이
/// 이 기능의 전부다. 어디로 들어왔는지(`target`)와 지금 역할, 그리고 관리자가 손을
/// 댔는지 셋으로 갈린다.
@Suite("웹 콘솔로 들어오면 개발자가 된다")
struct ConsoleVisitorRoleTests {
    private let controller = AuthController()

    private func user(role: UserRole, setByAdmin: Bool = false) -> User {
        User(
            subject: "sub",
            email: "someone@example.com",
            name: "누군가",
            role: role,
            roleSetByAdmin: setByAdmin
        )
    }

    @Test("웹으로 들어온 일반 사용자는 개발자가 된다")
    func webVisitorBecomesDeveloper() {
        let person = user(role: .user)
        #expect(controller.promoteIfConsoleVisitor(person, target: .web))
        #expect(person.role == .developer)
    }

    /// 스토어 앱은 앱을 받는 도구다. 거기만 쓰는 사람에게 등록 권한을 줄 이유가 없다.
    @Test("스토어 앱으로 들어온 사람은 그대로 둔다")
    func appVisitorStaysUser() {
        let person = user(role: .user)
        #expect(!controller.promoteIfConsoleVisitor(person, target: .app))
        #expect(person.role == .user)
    }

    /// **이것이 없으면 역할 화면이 눌리기만 하고 아무것도 바꾸지 못한다.** 관리자가
    /// 내려둔 계정이 다음 웹 로그인에 다시 올라간다.
    @Test("관리자가 정한 역할은 되돌리지 않는다")
    func adminDecisionSticks() {
        let person = user(role: .user, setByAdmin: true)
        #expect(!controller.promoteIfConsoleVisitor(person, target: .web))
        #expect(person.role == .user)
    }

    @Test("이미 개발자거나 관리자면 건드리지 않는다", arguments: [UserRole.developer, .admin])
    func higherRolesUntouched(_ role: UserRole) {
        let person = user(role: role)
        #expect(!controller.promoteIfConsoleVisitor(person, target: .web))
        #expect(person.role == role)
    }

    /// 관리자가 역할을 정하면 표시가 남아야 한다. 남지 않으면 위의 "되돌리지 않는다"
    /// 가 영영 켜지지 않아서, 있으나 마나 한 칸이 된다.
    @Test("관리자가 역할을 정하면 표시가 남는다")
    func changingRoleMarksIt() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            #expect(!target.roleSetByAdmin)

            try await AdminOperations.changeRole(
                of: target,
                to: .user,
                by: admin,
                on: app.db,
                logger: app.logger
            )

            let saved = try #require(try await User.find(try target.requireID(), on: app.db))
            #expect(saved.role == .user)
            #expect(saved.roleSetByAdmin)
        }
    }
}
