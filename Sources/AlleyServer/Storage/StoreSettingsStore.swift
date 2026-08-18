import AlleyShared
import Fluent
import Foundation
import Vapor

extension StoreSettings {
    /// 설정 행을 읽는다. 없으면 환경변수 초기값으로 한 번 만든다.
    ///
    /// **환경변수는 최초 1회만 쓰인다.** 행이 생긴 뒤로는 데이터베이스가 진실이고
    /// 환경변수는 무시된다. 그러지 않으면 화면에서 바꾼 값이 재시작할 때마다
    /// 되돌아가고, 어느 쪽이 진짜인지 아무도 모르게 된다.
    ///
    /// 씨앗을 마이그레이션이 아니라 최초 접근 시점에 심는 이유는, 마이그레이션이
    /// 서버와 별도 명령으로 돌아서 그 시점에 환경변수가 같다는 보장이 없기 때문이다.
    public static func loadOrSeed(
        on database: any Database,
        seed: AppConfig.StoreSeed,
        logger: Logger
    ) async throws -> StoreSettings {
        if let existing = try await find(singletonID, on: database) {
            return existing
        }

        let settings = StoreSettings(
            storeName: seed.name,
            logoURL: seed.logoURL,
            accentColor: seed.accentColor,
            allowedEmailDomains: seed.allowedEmailDomains,
            bundleIDPrefix: seed.bundleIDPrefix,
            enforceBundleIDPrefix: seed.enforceBundleIDPrefix
        )

        do {
            try await settings.create(on: database)
            logger.notice("스토어 설정을 환경변수 초기값으로 만들었습니다. 이후 변경은 관리자 화면에서 합니다.")
            return settings
        } catch {
            // 두 요청이 동시에 씨앗을 심으려 하면 한쪽이 기본키 중복으로 실패한다.
            // 진 쪽은 이긴 쪽이 만든 행을 그대로 쓰면 된다.
            guard let existing = try await find(singletonID, on: database) else { throw error }
            return existing
        }
    }
}

extension Request {
    /// 이 요청에서 쓸 스토어 설정.
    ///
    /// 요청마다 조회한다. 캐시를 두지 않는 이유는 서버가 여러 대일 때 한 대에서 바꾼
    /// 설정이 다른 대의 캐시에 반영되지 않기 때문이다. 조용히 낡은 값을 쓰는 것보다
    /// 기본키 조회 한 번이 낫다. 이 비용이 실제로 문제가 되면 그때 무효화 방법과
    /// 함께 캐시를 넣는다.
    public func storeSettings() async throws -> StoreSettings {
        try await StoreSettings.loadOrSeed(
            on: db,
            seed: application.alleyConfig.store.seed,
            logger: logger
        )
    }
}
