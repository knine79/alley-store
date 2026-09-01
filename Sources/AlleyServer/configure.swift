import AlleyShared
import Fluent
import FluentPostgresDriver
import JWT
import Leaf
import SotoS3
import Vapor

/// 애플리케이션 부트스트랩.
///
/// 테스트에서도 같은 경로를 타도록 설정 주입을 인자로 받는다.
public func configure(_ app: Application, config: AppConfig) async throws {
    app.alleyConfig = config

    try configureDatabase(app, config: config.database)
    configureMigrations(app)
    await configureJWT(app, config: config.security)
    try configureStorage(app, config: config.storage)

    configureContentCoders()
    app.views.use(.leaf)
    // 정적 파일 주소에 붙일 지문. 파일이 바뀌면 값이 바뀌어 브라우저가 새로 받는다.
    app.assetVersion = AssetVersion(publicDirectory: app.directory.publicDirectory)
    configureMiddleware(app)

    // 업로드는 presigned URL로 스토리지에 직접 올라가므로
    // 서버가 큰 바디를 받을 일이 없다.
    app.routes.defaultMaxBodySize = "1mb"

    // 조용해진 워커를 주기적으로 찾아 알린다.
    app.lifecycle.use(WorkerWatchdog())

    try routes(app)
}

/// JSON 의 날짜 형식.
///
/// Vapor 기본값은 기준 시각으로부터의 초를 담은 실수다. 사람이 읽을 수 없고, 다른
/// 언어에서 해석하려면 Apple 의 기준 시각을 알아야 한다. 스토어 앱과 워커가 같은
/// 형식을 읽어야 하고 이 API 는 언젠가 사내 다른 도구도 부르게 되므로 ISO-8601 로
/// 고정한다.
private func configureContentCoders() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
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

    // apps → versions → artifacts 순으로 외래키가 걸린다.
    app.migrations.add(CreateApp())
    app.migrations.add(CreateAppMember())
    app.migrations.add(CreateVersionEnums())
    app.migrations.add(CreateVersion())
    app.migrations.add(CreateArtifact())
    app.migrations.add(CreateDownload())

    // 워커가 있어야 잡이 워커를 참조할 수 있다.
    app.migrations.add(CreateWorker())
    app.migrations.add(CreateSigningJobEnum())
    app.migrations.add(CreateSigningJob())

    // CI 파이프라인이 쓰는 앱별 배포 토큰 (ADR-0015).
    app.migrations.add(CreateDeployToken())

    // 별점·피드백과 알림 대상.
    app.migrations.add(CreateFeedback())
    app.migrations.add(CreateNotificationTarget())
    app.migrations.add(AddWorkerAlertedAt())

    // 설정 행은 마이그레이션이 아니라 최초 접근 시점에 심는다 (ADR-0011).
    // 표 자체는 여기서 만들고, 뒤에 붙는 열은 그다음에 온다.
    app.migrations.add(CreateStoreSettings())
    app.migrations.add(AddAnonymousFeedbackSetting())
}

/// 미들웨어 스택.
///
/// 기본 스택을 그대로 두지 않고 새로 쌓는다. Vapor 기본값에는 언제나 JSON 을 주는
/// `ErrorMiddleware` 가 들어 있는데, 웹 콘솔에서 주소를 잘못 치면 사용자가
/// `{"error":true,...}` 를 보게 된다.
///
/// 순서가 중요하다. 오류 처리가 가장 바깥에 있어야 안쪽에서 난 오류를 다 잡는다.
private func configureMiddleware(_ app: Application) {
    app.middleware = .init()
    app.middleware.use(ConsoleErrorMiddleware())
    // 쿠키로 인증된 상태 변경 요청의 출처를 확인한다 (ADR-0010 후속).
    app.middleware.use(OriginCheckMiddleware())
    // 정적 파일이 브라우저에 눌러앉지 않게 한다. FileMiddleware 보다 바깥에 둬야
    // 그쪽이 만든 응답에 헤더를 붙일 수 있다.
    app.middleware.use(StaticCacheMiddleware())
    // Public/ 의 정적 파일. 라우트에서 못 찾으면 여기서 찾는다.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
}

/// 오브젝트 스토리지 연결.
///
/// `AWSClient` 는 커넥션 풀을 들고 있어서 요청마다 만들면 안 되고, 종료할 때
/// 반드시 닫아야 한다. 그래서 애플리케이션 수명에 묶는다.
private func configureStorage(_ app: Application, config: AppConfig.StorageConfig) throws {
    let client = AWSClient(
        credentialProvider: .static(
            accessKeyId: config.accessKeyID,
            secretAccessKey: config.secretAccessKey
        )
    )

    let storage: ArtifactStorage
    do {
        storage = try ArtifactStorage(client: client, config: config)
    } catch {
        // 설정이 틀려서 못 만들었으면 클라이언트를 여기서 닫는다.
        // 수명 훅을 아직 안 걸었으므로 아무도 대신 닫아주지 않는다.
        try? client.syncShutdown()
        throw error
    }

    app.lifecycle.use(AWSClientLifecycle(client: client))
    app.artifactStorage = storage
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
