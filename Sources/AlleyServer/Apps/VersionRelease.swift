import Fluent
import Vapor

/// 버전을 출시한다. 웹 콘솔과 API 가 모두 여기를 지난다 (ADR-0075).
///
/// **출시가 일어나는 곳을 하나로 모은다.** CLI 와 MCP 는 API 를 부르므로, 웹과 API
/// 두 핸들러가 이것을 부르면 네 갈래가 모두 같은 규칙을 지난다. 갈래마다 따로 붙이면
/// 한 곳에서 빠진다. 실제로 번들 ID 검사가 웹에만 있었다.
enum VersionRelease {
    /// 권한 확인은 부르는 쪽이 한다. 세션과 배포 토큰이 확인하는 방법이 다르다.
    ///
    /// `announce` 가 true 이면 저장한 뒤 앱의 출시 소식 채널에 알린다. 스토어 앱은
    /// 알리지 않는다. 스스로 업데이트하고, 공유 링크도 상세가 아니라 설치 페이지로 간다.
    static func release(_ version: Version, announce: Bool, on request: Request) async throws {
        // 번들 ID 가 확정되지 않은 앱은 출시할 수 없다 (ADR-0034).
        //
        // 스토어 앱은 `CFBundleIdentifier` 로 설치 여부를 판단한다. 임시값인 채로
        // 내보내면 받은 사람의 맥에서 영영 "설치 안 됨" 으로 남고, 업데이트도
        // 잡히지 않는다. 받아간 뒤에 고쳐도 이미 나간 것은 되돌릴 수 없다.
        guard !version.app.bundleIDPending else {
            throw Abort(
                .conflict,
                reason: """
                    번들 ID 가 아직 확정되지 않아 출시할 수 없습니다. 서명 워커가 \
                    번들을 열어 번들 ID 를 읽어야 확정됩니다. 서명이 실패했다면 \
                    고친 뒤 다시 올리세요.
                    """
            )
        }

        // 출시하기 전에 센다. 저장한 뒤에 세면 이 버전이 끼어 언제나 업데이트가 된다.
        let isFirstRelease = announce
            ? try await ReleaseNews.isFirstRelease(of: version, on: request.db)
            : false

        try version.transition(to: .released)
        try await version.save(on: request.db)

        guard announce else { return }
        // 여기서 던지면 출시는 저장됐는데 오류가 돌아간다. CI 는 실패로 알고 다시
        // 출시하려다 409 를 받는다. 스토어 앱인지 모르겠으면 알리지 않는다.
        let storeAppID: UUID?
        do {
            storeAppID = try await request.storeAppSettings().$app.id
        } catch {
            return
        }
        // 스토어 앱이 아직 없는 스토어도 있다. 그때 nil 은 "스토어 앱이 아니다" 다.
        guard storeAppID != version.$app.id else { return }
        await ReleaseNews.announce(
            version, of: version.app, isFirstRelease: isFirstRelease, on: request
        )
    }
}
