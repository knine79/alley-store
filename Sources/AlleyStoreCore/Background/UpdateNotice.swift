import AlleyShared
import Foundation

/// 스토어 앱이 꺼져 있을 때 띄울 업데이트 알림 (이슈 #74, ADR-0080).
///
/// 무엇을 알릴지만 정한다. 서버에 묻고 알림을 띄우는 일은 `BackgroundUpdateCheck` 가 한다.
/// 둘을 나눈 것은 시험 때문이다. 여기에는 네트워크도 알림 센터도 없다.
struct UpdateNotice: Equatable {
    var title: String
    var body: String

    /// 알림 하나에 이름을 적는 앱 수. 넘으면 "외 N개" 로 줄인다.
    static let namedLimit = 3

    /// 업데이트가 있는 앱들. 이름순이다.
    ///
    /// **스토어 앱 자신은 넣지 않는다.** 열면 스스로 갈아끼우므로(ADR-0073) 알려서 열게 할
    /// 일이 아니다. 출시본이 없는 앱과 깔려 있지 않은 앱도 뺀다. 업데이트가 아니다.
    static func pending(
        in apps: [AppDTO],
        installed: [String: InstalledApp],
        isSelf: (AppDTO) -> Bool
    ) -> [AppDTO] {
        apps
            .filter { app in
                !isSelf(app)
                    && InstallState.compare(installed: installed[app.bundleID], released: app.latestReleasedVersion)
                        == .updateAvailable
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 알릴 것과, 알린 뒤 기억해 둘 것.
    ///
    /// **이미 알린 버전만 남았으면 알리지 않는다.** 4시간마다 같은 알림이 오면 읽지 않고
    /// 끈다. 새 버전이 하나라도 생기면 그때는 남아 있던 것까지 묶어 한 통으로 알린다.
    /// 사람이 알고 싶은 것은 "지금 받을 것이 몇 개인가" 다.
    ///
    /// 기억은 지금 업데이트가 있는 앱만 남긴다. 업데이트한 앱은 지워져서, 나중에 같은
    /// 앱에 새 버전이 나오면 다시 알린다.
    static func plan(
        pending: [AppDTO],
        notified: [String: String]
    ) -> (notice: UpdateNotice?, remember: [String: String]) {
        var remember: [String: String] = [:]
        for app in pending {
            guard let version = app.latestReleasedVersion else { continue }
            remember[app.bundleID] = version.id.uuidString
        }
        let isNew = pending.contains { app in
            notified[app.bundleID] != remember[app.bundleID]
        }
        return (isNew ? notice(for: pending) : nil, remember)
    }

    /// 알림 문구. 앱이 하나면 그 앱과 버전을, 여럿이면 수와 이름을 적는다.
    static func notice(for pending: [AppDTO]) -> UpdateNotice? {
        guard let first = pending.first else { return nil }
        if pending.count == 1 {
            let version = first.latestReleasedVersion?.shortVersion ?? ""
            return UpdateNotice(
                title: "\(first.name) 업데이트",
                body: "\(version) \(subjectParticle(version)) 나왔습니다. 눌러서 업데이트하세요."
            )
        }
        let names = pending.prefix(namedLimit).map(\.name).joined(separator: ", ")
        let rest = pending.count - namedLimit
        let who = rest > 0 ? "\(names) 외 \(rest)개" : names
        return UpdateNotice(
            title: "업데이트 \(pending.count)개",
            body: "\(who)의 새 버전이 나왔습니다. 눌러서 업데이트하세요."
        )
    }

    /// 이/가. 버전 끝자리는 대개 숫자라 읽는 소리로 고른다 (`Josa`). 모르면 둘 다 적는다.
    private static func subjectParticle(_ word: String) -> String {
        switch Josa.final(of: word) {
        case .none?: return "가"
        case .rieul?, .other?: return "이"
        case nil: return "이(가)"
        }
    }
}
