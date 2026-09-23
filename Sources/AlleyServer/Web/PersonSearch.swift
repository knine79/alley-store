import Fluent
import Foundation
import Vapor

/// 사람을 이름이나 이메일로 찾는다.
///
/// **두 화면이 같은 것을 쓴다.** 앱의 업로드 권한 주기와, 주인이 끊긴 앱의 오너
/// 정하기다 (ADR-0061). 각자 적으면 한쪽만 이름으로 찾게 되는 날이 온다.
///
/// 이름과 이메일 어느 쪽으로 쳐도 걸리게 한다. 사람을 부르는 이름과 계정을 가리키는
/// 이메일이 머릿속에서 따로 놀아서, 한쪽만 받으면 "분명 있는데 안 나온다" 가 된다.
///
/// 이미 권한이 있는 사람은 부르는 쪽이 `excluding` 으로 뺀다. 눌러도 아무 일이 없는
/// 줄을 보여줄 이유가 없다.
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
            // 끊은 계정은 후보가 아니다. 넘겨봐야 그 자리에서 다시 주인을 잃는다.
            .filter(\.$deactivatedAt == nil)

        // **제외를 질의에 넣는다.** 스무 명을 받아온 뒤에 걸러내면, 앞쪽이 전부 이미
        // 권한 있는 사람일 때 결과가 통째로 비어 "찾은 사람이 없습니다" 가 뜬다.
        // 스물한 번째에 있는 사람은 영영 보이지 않는다.
        if !already.isEmpty {
            builder = builder.filter(\.$id !~ Array(already))
        }

        let found = try await builder
            .sort(\.$name)
            .limit(limit + 1)
            .all()
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
