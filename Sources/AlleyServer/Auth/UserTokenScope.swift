import AlleyShared
import Vapor

/// 사람 토큰으로 부를 수 있는 경로 (ADR-0060).
///
/// **막을 것이 아니라 열 것을 적는다.** 처음에는 "지우는 것만 막자" 였는데, 그러면
/// `POST /api/v1/apps/:id/deploy-tokens` 가 열려 있다. 그것으로 만든 배포 토큰은
/// 만료도 없고 계정을 끊어도 살아남아서, 90일 수명과 퇴사 차단을 한 번에 넘어간다.
/// 막을 것을 세는 규칙은 경로가 늘어날 때마다 새는 곳이 생긴다.
///
/// 여기 적힌 것은 MCP 도구가 실제로 쓰는 것뿐이다. 도구를 늘리려면 이 목록에 한 줄을
/// 더해야 하고, 그때 "이 토큰으로 이것까지 되어도 되나" 를 한 번 보게 된다.
enum UserTokenScope {
    /// 열려 있는 한 줄. 경로는 `/` 로 끊어 맞추고 `*` 는 아무 조각이나 받는다.
    private struct Rule {
        var method: HTTPMethod
        var pattern: [String]
    }

    private static let rules: [Rule] = [
        // 나는 누구인가. 붙었는지 확인하는 데 쓴다.
        Rule(method: .GET, pattern: ["api", "v1", "me"]),

        // 앱과 버전.
        Rule(method: .GET, pattern: ["api", "v1", "apps"]),
        Rule(method: .GET, pattern: ["api", "v1", "apps", "*"]),
        Rule(method: .GET, pattern: ["api", "v1", "apps", "*", "versions"]),
        Rule(method: .POST, pattern: ["api", "v1", "apps", "*", "versions"]),
        Rule(method: .GET, pattern: ["api", "v1", "versions", "*"]),
        Rule(method: .POST, pattern: ["api", "v1", "versions", "*", "complete"]),
        Rule(method: .POST, pattern: ["api", "v1", "versions", "*", "release"]),

        // 서명이 어디까지 왔는지, 무엇을 고치면 되는지.
        Rule(method: .GET, pattern: ["api", "v1", "versions", "*", "signing"]),

        // 앱에 넣을 공개키와 쓸 수 있는 상태인지 (ADR-0057).
        Rule(method: .GET, pattern: ["api", "v1", "apps", "*", "sparkle"]),

        // 들어온 별점과 피드백.
        Rule(method: .GET, pattern: ["api", "v1", "apps", "*", "feedback"]),
    ]

    /// 이 메서드와 경로가 열려 있나.
    static func allows(method: HTTPMethod, path: String) -> Bool {
        let parts = path
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "/")
            .map(String.init)
        return rules.contains { rule in
            rule.method == method && matches(parts, rule.pattern)
        }
    }

    private static func matches(_ parts: [String], _ pattern: [String]) -> Bool {
        guard parts.count == pattern.count else { return false }
        for (part, expected) in zip(parts, pattern) where expected != "*" && part != expected {
            return false
        }
        return true
    }
}
