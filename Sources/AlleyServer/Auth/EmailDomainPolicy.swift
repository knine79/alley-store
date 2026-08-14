import Foundation

/// 어떤 계정이 이 스토어에 로그인할 수 있는지 판단한다.
///
/// 이 판단은 반드시 서버에서 한다. 클라이언트가 보낸 값이나 클라이언트의 검증
/// 결과를 믿으면 우회할 수 있다. 그래서 이 타입은 네트워크도 데이터베이스도
/// 모르는 순수 함수로 두고, 로그인 경로에서만 호출한다.
public struct EmailDomainPolicy: Sendable, Equatable {
    /// 허용할 도메인 목록. 비어 있으면 도메인 제한을 걸지 않는다.
    public let allowedDomains: [String]

    public init(allowedDomains: [String]) {
        // 비교를 소문자 기준으로 통일한다. 이메일 도메인은 대소문자를 구분하지 않는다.
        self.allowedDomains = allowedDomains
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case emailMissing
        case emailNotVerified
        case malformedEmail(String)
        case domainNotAllowed(domain: String)
        /// 이메일 도메인과 Google 이 알려준 조직 도메인(`hd`)이 다르다.
        case hostedDomainMismatch(email: String, hostedDomain: String)

        public var description: String {
            switch self {
            case .emailMissing:
                return "계정에 이메일이 없습니다."
            case .emailNotVerified:
                return "이메일이 인증되지 않은 계정입니다."
            case .malformedEmail(let value):
                return "이메일 형식이 올바르지 않습니다: \(value)"
            case .domainNotAllowed(let domain):
                return "'\(domain)' 도메인은 이 스토어에 로그인할 수 없습니다."
            case .hostedDomainMismatch(let email, let hostedDomain):
                return "이메일 도메인과 조직 도메인이 다릅니다: \(email) / \(hostedDomain)"
            }
        }
    }

    /// 로그인을 허용할지 판단한다.
    ///
    /// - Parameters:
    ///   - email: ID 토큰의 `email` claim.
    ///   - emailVerified: ID 토큰의 `email_verified` claim.
    ///   - hostedDomain: ID 토큰의 `hd` claim. 개인 계정에는 없다.
    /// - Returns: 정규화된(소문자) 이메일.
    @discardableResult
    public func admit(
        email: String?,
        emailVerified: Bool?,
        hostedDomain: String?
    ) throws(Rejection) -> String {
        guard let rawEmail = email?.trimmingCharacters(in: .whitespaces), !rawEmail.isEmpty else {
            throw .emailMissing
        }
        let normalized = rawEmail.lowercased()

        // 미인증 이메일은 소유가 증명되지 않았다. 도메인만 보고 통과시키면
        // 남의 주소를 등록한 계정이 들어올 수 있다.
        guard emailVerified == true else { throw .emailNotVerified }

        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw .malformedEmail(normalized)
        }
        let domain = String(parts[1])

        // `hd` 는 Google Workspace 계정에만 붙는다. 있으면 이메일 도메인과 일치해야 한다.
        // 둘이 다르면 계정 구성이 예상 밖이라는 뜻이므로 통과시키지 않는다.
        if let hostedDomain {
            let normalizedHostedDomain = hostedDomain.trimmingCharacters(in: .whitespaces).lowercased()
            if !normalizedHostedDomain.isEmpty, normalizedHostedDomain != domain {
                throw .hostedDomainMismatch(email: normalized, hostedDomain: normalizedHostedDomain)
            }
        }

        // 목록이 비어 있으면 제한하지 않는다. 셀프호스팅 초기 설정 편의를 위한 것이고,
        // 운영에서는 반드시 채워야 한다.
        guard !allowedDomains.isEmpty else { return normalized }

        guard allowedDomains.contains(domain) else {
            throw .domainNotAllowed(domain: domain)
        }
        return normalized
    }
}
