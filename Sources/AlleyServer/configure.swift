import AlleyShared
import Fluent
import FluentPostgresDriver
import JWT
import Leaf
import Vapor

/// 애플리케이션 부트스트랩.
///
/// 테스트에서도 같은 경로를 타도록 설정 주입을 인자로 받는다.
public func configure(_ app: Application, config: AppConfig) async throws {
    app.alleyConfig = config

    try configureDatabase(app, config: config.database)
    configureMigrations(app)
    await configureJWT(app, config: config.security)

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

private func configureMigrations(_ app: Application) {
    // 순서가 곧 의존 관계다. enum 타입이 있어야 users 를 만들 수 있고,
    // users 가 있어야 auth_codes 의 외래키를 걸 수 있다.
    app.migrations.add(CreateUserRoleEnum())
    app.migrations.add(CreateUser())
    app.migrations.add(CreateAuthCode())
}

private func configureJWT(_ app: Application, config: AppConfig.SecurityConfig) async {
    // 세션 토큰과 OAuth state 토큰을 서명하는 키.
    await app.jwt.keys.add(hmac: .init(from: config.jwtSecret), digestAlgorithm: .sha256)
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
