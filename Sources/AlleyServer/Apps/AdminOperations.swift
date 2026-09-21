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
