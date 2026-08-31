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
                reason: """
                    허용 도메인을 비우면 어떤 계정이든 로그인할 수 있습니다. \
                    정말 그렇게 하려면 confirmOpenToAnyDomain 을 함께 보내세요.
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
        try await target.save(on: database)

        logger.notice(
            "역할 변경 [대상: \(target.email), \(previous.rawValue) → \(role.rawValue), 관리자: \(admin.email)]"
        )
    }
}
