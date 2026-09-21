import AlleyShared
import Fluent
import Foundation
import Vapor

/// Sparkle 을 실제로 쓸 수 있는 상태인지 (ADR-0057).
///
/// **피드가 내려와도 업데이트가 안 되는 상태가 있었다.** Sparkle 2 는 appcast 의
/// `sparkle:edSignature` 를 앱의 `SUPublicEDKey` 로 검증하고, 서명이 없으면 조용히
/// 아무것도 하지 않는다. 그런데 워커에 Sparkle 키가 없으면 서명이 그냥 빠진다.
/// 실패하지 않고 빠진다(`SigningPipeline.sparkleSignature`).
///
/// 화면은 그동안 "앱의 `SUFeedURL` 에 넣으세요" 라고만 적혀 있었다. 그대로 따라 하면
/// 피드는 내려오는데 업데이트가 안 되고, 어디를 봐야 할지 알 수 없다.
///
/// 그래서 피드 주소를 내주는 자리에서 두 가지를 함께 말한다.
///
/// - 앱에 넣을 `SUPublicEDKey` 값. 서버가 워커에게 받아둔 것이다
/// - 이 앱의 최근 결과물에 서명이 실제로 붙어 있는지
struct SparkleReadinessRow: Encodable {
    /// 앱의 `Info.plist` 에 넣을 값. 쓸 수 있는 워커가 없으면 nil.
    var publicKey: String?
    /// 워커마다 키가 다르다. 그러면 어느 워커가 집었느냐에 따라 갈린다.
    var hasConflictingKeys: Bool
    /// 이 앱의 최근 출시본에 Sparkle 서명이 붙어 있나.
    var latestReleaseIsSigned: Bool
    /// 아직 출시본이 없어서 판단할 수 없다.
    var hasNoRelease: Bool
    /// 사람에게 보일 한 줄. nil 이면 문제 없음.
    ///
    /// **계산 프로퍼티로 두면 안 된다.** `Encodable` 합성 인코딩은 저장 프로퍼티만
    /// 담아서, 계산한 값은 Leaf 까지 가지 않는다. 화면이 조용히 아무것도 안 그린다.
    var blocker: String?

    /// 지금 피드 주소를 내줄 만한가.
    ///
    /// **공개키를 하나로 말할 수 없으면 발급하지 않는다.** 워커에 키가 없으면 결과물에
    /// 서명이 안 붙고, 워커마다 키가 다르면 앱에 적을 값을 고를 수 없다. 둘 다 주소를
    /// 넣어도 업데이트가 되지 않는 상태다.
    ///
    /// 주소만 내주고 경고를 곁들이는 것으로는 부족했다. 발급 버튼이 있으면 누르고,
    /// 누르면 주소가 나오고, 주소가 나오면 된 줄 안다. 경고는 그 위에 한 줄로 남는다.
    ///
    /// **이미 발급한 것은 건드리지 않는다.** 그 주소로 피드는 그대로 내려간다. 서명이
    /// 빠질 뿐이고, 키를 넣으면 다음 버전부터 붙는다. 여기서 막는 것은 새로 내주는
    /// 것뿐이다.
    ///
    /// `blocker` 와 같은 이유로 저장 프로퍼티다. 계산한 값은 Leaf 까지 가지 않는다.
    var canIssue: Bool

    /// 위 값들로 한 줄을 고른다. nil 이면 문제 없음.
    static func blocker(
        publicKey: String?,
        hasConflictingKeys: Bool,
        latestReleaseIsSigned: Bool,
        hasNoRelease: Bool
    ) -> String? {
        if hasConflictingKeys {
            return """
                서명 워커들이 서로 다른 Sparkle 키를 쓰고 있습니다. 앱은 공개키를 하나만 \
                읽으므로, 어느 워커가 서명했느냐에 따라 업데이트가 되기도 하고 안 되기도 \
                합니다. 모든 워커에 같은 키를 넣으세요.
                """
        }
        if publicKey == nil {
            // 왜 안 되는지를 길게 적어봐야, 이 화면에서 할 수 있는 것이 없다. 무엇이
            // 없어서 막혔는지만 적고 고치는 사람은 아래 안내가 가리킨다.
            return "서명 워커에 Sparkle 키가 없어서 설정할 수 없습니다."
        }
        if hasNoRelease { return nil }
        if !latestReleaseIsSigned {
            return """
                이 앱의 최근 출시본에 Sparkle 서명이 없습니다. 그 버전이 나갈 때 워커에 \
                키가 없었다는 뜻입니다. 지금은 키가 있으니, 다음 버전부터 서명이 붙습니다.
                """
        }
        return nil
    }

    static func of(app: App, on database: any Database) async throws -> SparkleReadinessRow {
        // 폐기된 워커는 보지 않는다. 더 이상 서명하지 않으므로 그 키가 달라도
        // 지금 배포에 영향이 없다.
        let keys = try await Worker.query(on: database)
            .filter(\.$revokedAt == nil)
            .all()
            .compactMap(\.sparklePublicKey)
        let distinct = Set(keys)

        // 최근 출시본 하나만 본다. 그 이전 것은 이미 나간 뒤라 지금 고칠 수 없고,
        // 화면이 말해야 하는 것은 "다음에 어떻게 되는가" 다.
        let latest = try await Version.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .filter(\.$state == .released)
            .with(\.$artifacts)
            .sort(\.$buildNumber, .descending)
            .first()

        let publicKey = distinct.count == 1 ? distinct.first : nil
        let hasConflictingKeys = distinct.count > 1
        let latestReleaseIsSigned = latest?.artifacts.contains {
            $0.kind == .signed && $0.edSignature?.isEmpty == false
        } ?? false
        let hasNoRelease = latest == nil

        return SparkleReadinessRow(
            publicKey: publicKey,
            hasConflictingKeys: hasConflictingKeys,
            latestReleaseIsSigned: latestReleaseIsSigned,
            hasNoRelease: hasNoRelease,
            blocker: blocker(
                publicKey: publicKey,
                hasConflictingKeys: hasConflictingKeys,
                latestReleaseIsSigned: latestReleaseIsSigned,
                hasNoRelease: hasNoRelease
            ),
            // 키가 아예 없을 때도, 워커마다 다를 때도 `publicKey` 가 nil 이다. 둘 다
            // 앱에 적을 값을 말해줄 수 없는 상태라 같은 규칙으로 막는다.
            canIssue: publicKey != nil
        )
    }
}
