import Fluent
import Vapor

/// 기동할 때 마이그레이션을 적용한다 (ADR-0028).
///
/// **권장 경로는 여전히 `alley-server migrate` 다.** 이건 일회성 명령을 돌릴 수단이
/// 없는 플랫폼을 위한 문이다. 컨테이너에 읽기 전용 명령만 허용하고 일회성 잡도 띄울
/// 수 없으면 스키마를 만들 방법이 남지 않는다.
///
/// 요청을 받기 전에 돌고, 실패하면 서버가 뜨지 않는다. `configure(_:config:)` 안에서
/// 부르므로 던진 오류가 그대로 진입점까지 올라간다. 반쯤 적용된 스키마로 트래픽을
/// 받는 것보다 안 뜨는 편이 낫다.
enum BootMigration {
    /// 다른 인스턴스가 마이그레이션을 돌리는 것을 기다리는 한도.
    ///
    /// 넘기면 **뜨지 않는다.** 잠금 없이 진행하는 선택지도 있지만 그건 이 잠금이
    /// 막으려던 상황(두 파드가 같은 `CREATE TABLE` 을 동시에 치는 것)을 그대로
    /// 만든다. 여기서 프로세스가 죽으면 플랫폼이 백오프를 두고 다시 띄우고, 그
    /// 재시작 횟수가 사람에게 보이는 신호가 된다. 조용히 오래 기다리는 쪽은 아무
    /// 신호도 남기지 않는다.
    ///
    /// 2분은 짐작이다. 지금 마이그레이션은 전부 표를 만들거나 열을 더하는 것이라
    /// 초 단위로 끝난다. 큰 표를 다시 쓰는 마이그레이션이 생기면 이 값이 짧아진다.
    static let lockTimeout: Duration = .seconds(120)

    /// 켜져 있으면 스키마를 맞춘다. 꺼져 있으면 아무것도 하지 않는다.
    static func runIfEnabled(
        on application: Application,
        config: AppConfig,
        waitingUpTo timeout: Duration = lockTimeout
    ) async throws {
        guard config.database.migrateOnBoot else { return }

        // 기본값이 아닌 상태로 돌고 있다는 것을 운영자가 로그에서 알아채야 한다.
        // 그래서 notice 가 아니라 warning 이다.
        application.logger.warning(
            """
            MIGRATE_ON_BOOT 이 켜져 있어 기동하면서 마이그레이션을 적용합니다. \
            이 설정은 롤아웃마다 마이그레이션을 돌리고, 실패하면 서버를 띄우지 않습니다. \
            일회성 명령(alley-server migrate)을 돌릴 수 있는 환경이라면 이 값을 끄고 그쪽을 쓰세요.
            """
        )

        try await AdvisoryLock.withLock(.migration, on: application, waitingUpTo: timeout) {
            // 적용 여부 판단을 Fluent 에 맡긴다. `autoMigrate()` 는 `_fluent_migrations`
            // 를 읽어 안 돈 것만 돌린다. 우리가 따로 확인하면 같은 표를 두 번 묻는
            // 셈이고, 두 판단이 어긋날 여지만 생긴다. 그 표를 만드는 것도 Fluent 이고
            // (`setupIfNeeded`) 그 `CREATE TABLE` 자체가 경쟁 대상이다.
            //
            // **우리가 보장하는 것은 순서다.** 이 읽기가 잠금 안에서 일어나므로,
            // 기다린 쪽은 먼저 돈 인스턴스가 커밋한 결과를 보고 시작한다. 잠금을
            // 잡기 전에 이걸 부르면 그 보장이 없어진다.
            try await application.autoMigrate()
        }

        application.logger.notice("기동 시 마이그레이션을 마쳤습니다.")
    }
}
