import AlleyShared
import Fluent
import FluentPostgresDriver
import Leaf
import Vapor

/// 애플리케이션 부트스트랩.
///
/// 테스트에서도 같은 경로를 타도록 설정 주입을 인자로 받는다.
public func configure(_ app: Application, config: AppConfig) async throws {
    app.alleyConfig = config

    try configureDatabase(app, config: config.database)

    app.views.use(.leaf)

    // 업로드는 presigned URL로 스토리지에 직접 올라가므로
    // 서버가 큰 바디를 받을 일이 없다.
    app.routes.defaultMaxBodySize = "1mb"

    try routes(app)
}

private func configureDatabase(_ app: Application, config: AppConfig.DatabaseConfig) throws {
    var postgres = try SQLPostgresConfiguration(url: config.url)
    // 컨테이너 사이 연결에는 TLS를 요구하지 않는다.
    // 운영 환경의 TLS 종단은 인프라 계층이 담당한다.
    postgres.coreConfiguration.tls = .disable
    app.databases.use(.postgres(configuration: postgres), as: .psql)
}

/// 환경변수에서 설정을 읽어 부팅한다. 실제 실행 진입점이 쓴다.
public func configure(_ app: Application) async throws {
    let config: AppConfig
    do {
        config = try AppConfig.load()
    } catch {
        app.logger.critical("설정을 읽지 못했습니다: \(error)")
        throw error
    }
    try await configure(app, config: config)
}
