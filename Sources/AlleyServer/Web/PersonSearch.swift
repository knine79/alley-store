import Fluent
import Foundation
import Vapor

/// 사람을 이름이나 이메일로 찾는다.
///
/// **두 화면이 같은 것을 쓴다.** 앱의 업로드 권한 주기와, 주인이 끊긴 앱의 오너
/// 정하기다 (ADR-0061). 각자 적으면 한쪽만 이름으로 찾게 되는 날이 온다.
///
/// 이메일만 찾게 두지 않는 이유는, 사람이 동료의 이메일 철자를 정확히 기억하지
/// 못해서다. 이름은 화면에서 늘 보는 값이다.
enum PersonSearch {
    /// 화면에 세울 후보 수. 넘으면 더 좁혀 치라고 알린다.
    static let limit = 20

    struct Result {
        var candidates: [MemberCandidateRow]
        /// 세울 수보다 많았나.
        var overflowed: Bool
    }

    static func find(
        matching query: String,
        excluding already: Set<UUID> = [],
        includeInactive: Bool = false,
        on database: any Database
    ) async throws -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(candidates: [], overflowed: false) }

        let needle = "%\(trimmed.lowercased())%"
        var builder = User.query(on: database)
            .group(.or) { match in
                match.filter(\.$email, .custom("ILIKE"), needle)
                match.filter(\.$name, .custom("ILIKE"), needle)
            }
        if !includeInactive {
            // 끊은 계정은 후보가 아니다. 넘겨봐야 그 자리에서 다시 주인을 잃는다.
            builder = builder.filter(\.$deactivatedAt == nil)
        }

        let found = try await builder
            .sort(\.$name)
            .limit(limit + 1)
            .all()
            .filter { user in
                guard let id = try? user.requireID() else { return false }
                return !already.contains(id)
            }
            .map { user in
                MemberCandidateRow(
                    id: try user.requireID().uuidString,
                    email: user.email,
                    name: user.name
                )
            }

        return Result(candidates: Array(found.prefix(limit)), overflowed: found.count > limit)
    }
}
