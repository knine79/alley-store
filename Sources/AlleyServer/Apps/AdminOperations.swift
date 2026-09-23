import AlleyShared
import Fluent
import Foundation
import Vapor

/// 스토어 설정 변경과 역할 변경의 실제 규칙.
///
/// `AppRegistration` 과 같은 이유로 컨트롤러에서 꺼냈다. JSON API 와 웹 콘솔 폼이
/// **같은 코드를 지나야 한다.** 특히 허용 도메인을 비울 때 확인을 요구하는 규칙과
/// 마지막 관리자를 보호하는 규칙은 한쪽에만 있으면 그쪽으로 우회할 수 있다.
enum AdminOperations {
    /// 보낸 항목만 바꾼다.
    ///
    /// 화면에서 한 칸만 고쳤는데 안 보낸 항목이 기본값으로 덮이면 곤란하다.
    /// 그래서 요청 타입의 모든 항목이 옵셔널이고, nil 은 "건드리지 말라"는 뜻이다.
    static func updateSettings(
        _ payload: UpdateStoreSettingsRequest,
        of settings: StoreSettings,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws {
        if let storeName = payload.storeName {
            let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "스토어 이름은 비울 수 없습니다.")
            }
            settings.storeName = trimmed
        }

        // 빈 문자열은 "지우기"로 본다. 항목을 안 보낸 것과 구분된다.
        if let logoURL = payload.logoURL {
            settings.logoURL = logoURL.isEmpty
                ? nil
                : try StoreSettingsValidation.validatedLogoURL(logoURL)
        }
        if let accentColor = payload.accentColor {
            // 화면의 <style> 안에 그대로 들어가는 값이다. 오타 하나로 콘솔이
            // 통째로 깨지면 되돌릴 화면조차 안 보인다.
            settings.accentColor = accentColor.isEmpty
                ? nil
                : try StoreSettingsValidation.validatedAccentColor(accentColor)
        }
        if let prefix = payload.bundleIDPrefix {
            settings.bundleIDPrefix = prefix.isEmpty ? nil : prefix
        }
        if let enforce = payload.enforceBundleIDPrefix {
            settings.enforceBundleIDPrefix = enforce
        }
        if let allowsAnonymous = payload.allowsAnonymousFeedback {
            settings.allowsAnonymousFeedback = allowsAnonymous
        }

        if let domains = payload.allowedEmailDomains {
            settings.allowedEmailDomains = try normalize(
                domains: domains,
                confirmed: payload.confirmOpenToAnyDomain == true
            )
        }

        settings.$updatedBy.id = try admin.requireID()
        try await settings.save(on: database)

        // 로그인 문이 얼마나 열려 있는지는 사고가 났을 때 가장 먼저 확인할 값이다.
        // 누가 언제 무엇으로 바꿨는지 남긴다.
        logger.notice(
            "스토어 설정 변경 [관리자: \(admin.email), 허용 도메인: \(settings.allowedEmailDomains)]"
        )
    }

    /// 도메인 목록을 정규화하고, 비우는 경우에는 확인을 요구한다.
    ///
    /// 목록이 비면 조직 밖 계정도 전부 로그인할 수 있다. 예전에는 서버를 다시 배포해야
    /// 바꿀 수 있던 값이라 그 자체가 장벽이었는데, 화면에서 바꾸게 되면서 그 장벽이
    /// 사라졌다. 오타 한 번으로 그렇게 되는 것과, 그러겠다고 한 번 더 말하는 것은 다르다.
    private static func normalize(domains: [String], confirmed: Bool) throws -> [String] {
        let cleaned = domains
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        if cleaned.isEmpty, !confirmed {
            throw Abort(
                .badRequest,
                // 파라미터 이름을 사람에게 보여주지 않는다. 이 문구는 웹 화면의 빨간
                // 줄에 그대로 나오는데, 거기서 할 수 있는 일은 체크박스를 켜는 것이지
                // 필드를 "보내는" 것이 아니다.
                reason: """
                    허용 도메인을 비우면 어떤 계정이든 로그인할 수 있습니다. \
                    정말 그렇게 하려면 바로 아래의 확인을 켜고 다시 저장해주세요.
                    """
            )
        }

        // 중복을 없애되 관리자가 넣은 순서는 유지한다. 화면에서 순서가 뒤집히면 헷갈린다.
        var seen = Set<String>()
        return cleaned.filter { seen.insert($0).inserted }
    }

    /// 역할을 바꾼다.
    static func changeRole(
        of target: User,
        to role: UserRole,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws {
        // 마지막 관리자가 스스로 강등하면 아무도 설정을 못 바꾸게 된다.
        // 남은 관리자가 없어지는 변경만 막는다.
        if target.role.canAdminister, !role.canAdminister {
            let targetID = try target.requireID()
            let remaining = try await User.query(on: database)
                .filter(\.$role == .admin)
                .filter(\.$id != targetID)
                // 끊은 계정은 세지 않는다 (ADR-0061). 로그인하지 못하는 사람을 남은
                // 관리자로 치면, 아무도 들어올 수 없는 스토어가 이 검사를 통과한다.
                .filter(\.$deactivatedAt == nil)
                .count()
            guard remaining > 0 else {
                throw Abort(.badRequest, reason: "마지막 관리자의 역할은 바꿀 수 없습니다. 다른 관리자를 먼저 지정하세요.")
            }
        }

        let previous = target.role
        target.role = role
        // 여기를 지나면 자동 승격이 이 계정을 건너뛴다 (ADR-0056). 이 표시가 없으면
        // `user` 로 내려둔 계정이 다음 웹 로그인에 다시 `developer` 가 되어, 누르기는
        // 하는데 아무것도 바뀌지 않는 버튼이 된다.
        target.roleSetByAdmin = true
        try await target.save(on: database)

        logger.notice(
            "역할 변경 [대상: \(target.email), \(previous.rawValue) → \(role.rawValue), 관리자: \(admin.email)]"
        )
    }

    /// 계정을 끊은 결과.
    struct Deactivation: Sendable {
        /// 새 주인을 찾은 앱들.
        var moved: [(app: App, newOwner: User)] = []
        /// 함께 맡던 사람이 없어 주인이 비어버린 앱들. 관리자가 손으로 정해야 한다.
        var orphaned: [App] = []
    }

    /// 계정을 끊는다 (ADR-0061).
    ///
    /// **행을 지우지 않고 시각만 남긴다.** 누가 올렸고 누가 받아갔는지가 이 행을
    /// 가리킨다.
    ///
    /// **맡던 앱은 함께 맡던 사람에게 간다.** 그 앱에 업로드 권한이 있는 사람 중
    /// 가장 먼저 들어온 사람이다. 그 사람이 그 앱을 가장 오래 만졌을 가능성이 높고,
    /// 끊는 관리자는 대개 그 앱과 아무 관계가 없다. 관리자에게 몰아주면 목록만
    /// 길어지고 실제 담당자와 어긋난다.
    ///
    /// 함께 맡던 사람이 없으면 **넘기지 않는다.** 아무나 지목하는 것보다 비어 있는
    /// 것이 낫다. 대신 그 앱들을 돌려줘서 관리 화면이 "주인을 정해야 하는 앱" 으로
    /// 모아 보여준다. 끊긴 사람이 오너로 남아 있어도 그 계정은 로그인하지 못하고,
    /// 관리자는 여전히 그 앱을 만질 수 있다.
    ///
    /// **멤버십과 배포 토큰은 건드리지 않는다.** 로그인이 막히니 멤버로 남아도 할 수
    /// 있는 것이 없고, 복구하면 그대로 돌아온다. 배포 토큰은 앱의 자격증명이지 그
    /// 사람의 것이 아니라, 퇴사로 CI 가 멈추면 엉뚱한 곳을 뒤지게 된다.
    @discardableResult
    static func deactivate(
        _ target: User,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws -> Deactivation {
        let targetID = try target.requireID()
        let adminID = try admin.requireID()

        // 자기 계정을 끊으면 그 순간 자기가 로그인 상태를 잃는다. 되돌릴 화면에도
        // 못 들어간다.
        guard targetID != adminID else {
            throw Abort(.badRequest, reason: "자기 계정은 끊을 수 없습니다. 다른 관리자에게 부탁하세요.")
        }

        // **마지막 관리자를 따로 막지 않는다.** 여기 오는 사람은 로그인한 활성
        // 관리자이고(`requireAdmin`), 바로 위에서 자기 자신은 끊지 못하게 했다.
        // 그러니 끊고 나도 관리자가 최소 한 명, 곧 누른 사람이 남는다. 같은 것을
        // 한 번 더 세는 검사를 두면 절대 지나가지 않는 분기가 생기고, 그 분기는
        // 읽는 사람에게 "여기서 걸린다" 는 잘못된 안심을 준다.

        // 이미 끊긴 계정을 다시 눌러도 조용히 지나간다. 두 번 누른 사람에게 오류를
        // 보일 이유가 없고, 여기서 시각을 새로 쓰면 언제 끊었는지가 사라진다.
        guard target.isActive else { return Deactivation() }

        // **한 번에 되거나 아무것도 안 되거나.** 앱을 옮기다 중간에서 실패하면 일부만
        // 주인이 바뀐 채 계정은 살아 있게 된다. 그 상태는 화면 어디에도 드러나지
        // 않고, 다시 누르면 앞서 옮긴 것을 건너뛰어 요약이 달라진다.
        let result = try await database.transaction { db -> Deactivation in
            let owned = try await App.query(on: db)
                .filter(\.$owner.$id == targetID)
                .all()
            var moved: [(app: App, newOwner: User)] = []
            var orphaned: [App] = []
            for app in owned {
                if let heir = try await firstUploader(of: app, on: db) {
                    app.$owner.id = try heir.requireID()
                    try await app.save(on: db)
                    // 오너는 언제나 올릴 수 있으므로 멤버 표에서는 뺀다. 앱 화면이
                    // 지키는 규칙이다.
                    try await AppMember.query(on: db)
                        .filter(\.$app.$id == app.requireID())
                        .filter(\.$user.$id == heir.requireID())
                        .delete()
                    moved.append((app: app, newOwner: heir))
                } else {
                    orphaned.append(app)
                }
            }

            target.deactivatedAt = Date()
            try await target.save(on: db)
            return Deactivation(moved: moved, orphaned: orphaned)
        }

        logger.notice(
            """
            계정을 끊었습니다 [대상: \(target.email), 넘긴 앱: \(result.moved.count)개, \
            주인을 정해야 하는 앱: \(result.orphaned.count)개, 관리자: \(admin.email)]
            """
        )
        return result
    }

    /// 이 앱을 함께 맡던 사람 중 가장 먼저 들어온 사람.
    ///
    /// 끊긴 계정은 건너뛴다. 못 들어오는 사람에게 넘기면 그 앱은 그 자리에서 다시
    /// 주인을 잃는다.
    private static func firstUploader(
        of app: App,
        on database: any Database
    ) async throws -> User? {
        let members = try await AppMember.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .sort(\.$createdAt, .ascending)
            // 같은 시각에 들어온 둘은 정렬만으로 순서가 정해지지 않는다. 그러면
            // "가장 먼저 들어온 사람" 이 실행할 때마다 달라진다.
            .sort(\.$id, .ascending)
            .with(\.$user)
            .all()
        return members.map(\.user).first { $0.isActive }
    }

    /// 끊은 계정을 되돌린다.
    ///
    /// **넘어간 앱은 돌아오지 않는다.** 그동안 새 오너가 올렸을 수 있고, 돌려주는
    /// 것이 맞는지 여기서는 알 수 없다. 앱 화면에서 사람이 정합니다.
    static func reactivate(
        _ target: User,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws {
        guard !target.isActive else { return }
        target.deactivatedAt = nil
        try await target.save(on: database)
        logger.notice("계정을 되살렸습니다 [대상: \(target.email), 관리자: \(admin.email)]")
    }

    // MARK: - 워커

    /// 워커를 등록하고 토큰을 발급한다.
    ///
    /// 토큰 원문은 이 함수의 반환값에만 존재한다. 저장되는 것은 해시뿐이라(ADR-0013)
    /// 부르는 쪽이 화면에 한 번 보여주고 나면 서버 어디에도 남지 않는다.
    static func registerWorker(
        named name: String,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws -> CreatedWorker {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "워커 이름은 비울 수 없습니다.")
        }

        // 쓰고 있는 워커끼리는 이름이 겹치지 않게 한다. 목록에서 둘을 가릴 방법이 없고,
        // 잡 이력에 남는 것도 이름이라 나중에 "어느 맥이 서명했나" 를 되짚을 수 없다.
        // 폐기한 워커의 이름은 다시 쓸 수 있다. 맥을 교체하고 같은 이름을 붙이는 것이
        // 오히려 흔한 일이다.
        let sameName = try await Worker.query(on: database)
            .filter(\.$name == trimmed)
            .all()
        guard !sameName.contains(where: \.isActive) else {
            throw Abort(.conflict, reason: "'\(trimmed)' 은 이미 쓰고 있는 워커입니다. 이름을 바꾸거나 그 워커를 먼저 폐기하세요.")
        }

        let token = Worker.generateToken()
        let worker = Worker(
            name: trimmed,
            tokenHash: Worker.hash(token: token),
            createdByID: try admin.requireID()
        )
        try await worker.save(on: database)

        logger.notice("워커 등록 [이름: \(trimmed), 관리자: \(admin.email)]")
        return CreatedWorker(worker: try worker.toDTO(), token: token)
    }

    /// 워커 토큰을 폐기한다.
    ///
    /// 행을 지우지 않는다. 잡 이력이 이 워커를 가리키고 있어서, 지우면 "누가 서명했나"가
    /// 함께 사라진다. 폐기 시각만 남기고 토큰을 무효로 만든다.
    @discardableResult
    static func revokeWorker(
        _ workerID: UUID,
        by admin: User,
        on database: any Database,
        logger: Logger
    ) async throws -> Worker {
        guard let worker = try await Worker.find(workerID, on: database) else {
            throw Abort(.notFound, reason: "워커를 찾을 수 없습니다.")
        }
        guard worker.isActive else {
            throw Abort(.conflict, reason: "이미 폐기된 워커입니다.")
        }

        worker.revokedAt = Date()
        worker.currentJobID = nil
        try await worker.save(on: database)

        logger.notice("워커 폐기 [이름: \(worker.name), 관리자: \(admin.email)]")
        return worker
    }
}
