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
    // 옵트인일 때만, 요청을 받기 전에 스키마를 맞춘다 (ADR-0028).
    // 여기서 던지면 서버가 뜨지 않는다. 그게 의도다.
    try await BootMigration.runIfEnabled(on: app, config: config)
    await configureJWT(app, config: config.security)
    try configureStorage(app, config: config.storage)
    // 메일 클라이언트는 애플리케이션 한 곳의 설정을 본다. 설정이 없으면 아무것도
    // 하지 않고, 그때는 알림 채널 목록에서도 메일이 빠진다 (ADR-0058).
    app.configureSMTP(config.smtp)

    configureContentCoders()
    app.views.use(.leaf)
    // 정적 파일 주소에 붙일 지문. 파일이 바뀌면 값이 바뀌어 브라우저가 새로 받는다.
    app.assetVersion = AssetVersion(publicDirectory: app.directory.publicDirectory)
    configureMiddleware(app, config: config)

    // 업로드는 presigned URL로 스토리지에 직접 올라가므로
    // 서버가 큰 바디를 받을 일이 없다.
    app.routes.defaultMaxBodySize = "1mb"

    // 조용해진 워커를 주기적으로 찾아 알린다.
    app.lifecycle.use(
        PeriodicSweep(name: "워커 감시", interval: WorkerWatchdog.checkInterval) { application in
            await WorkerWatchdog.check(on: application)
        }
    )
    // 워커가 죽어 멈춘 서명 잡을 큐로 되돌린다.
    app.lifecycle.use(
        PeriodicSweep(name: "멈춘 서명 잡 회수", interval: StalledJobSweep.checkInterval) { application in
            await StalledJobSweep.run(on: application)
        }
    )
    // 업로드 통지 없이 버려진 draft 와 그 오브젝트를 지운다.
    app.lifecycle.use(
        PeriodicSweep(name: "방치된 draft 청소", interval: DraftSweep.checkInterval) { application in
            await DraftSweep.run(on: application)
        }
    )
    // 데이터베이스를 닫기 전에 긴 폴링을 내보낸다. 남겨두면 그것이 닫힌 데이터베이스를
    // 잡고 프로세스를 죽인다 (ADR-0052).
    app.lifecycle.use(ShutdownSignalLifecycle())

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
    // advisory lock 은 커넥션 풀 밖에서 직접 연결한다. 그 연결이 풀과 같은 값에서
    // 나와야 하므로 여기서 남긴다 (`AdvisoryLock`).
    app.postgresConfiguration = postgres.coreConfiguration
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

    // Sparkle 피드 (ADR-0017).
    app.migrations.add(CreateFeedToken())
    app.migrations.add(AddArtifactEdSignature())

    // 업로더가 함께 올리는 entitlements (ADR-0020).
    app.migrations.add(AddVersionEntitlements())

    // 서명 실패의 갈래 (ADR-0023).
    app.migrations.add(AddSigningJobFailureCode())
    app.migrations.add(AddAppBundleIDPending())
    app.migrations.add(AddWorkerVersion())
    app.migrations.add(CreateWorkerRelease())
    app.migrations.add(CreateOperatorToken())

    // 관리자가 올리는 브랜딩 이미지 (ADR-0045).
    app.migrations.add(CreateBrandingAsset())

    // 스토어 앱을 무엇으로 빌드할지 (ADR-0046).
    app.migrations.add(CreateStoreAppSettings())

    // 로그인 공급자를 Google 에서 표준 OIDC 로 넓힌다 (ADR-0047).
    app.migrations.add(AddIssuerToUser())

    // 번들에서 꺼낸 앱 아이콘.
    app.migrations.add(AddAppIconKey())

    // 스토어 앱을 받는 공개 페이지에는 세션이 없다 (ADR-0049).
    app.migrations.add(MakeDownloadUserOptional())

    // 스토어 앱은 dmg 로도 나간다 (ADR-0050).
    app.migrations.add(AddDiskImageArtifactKind())
    app.migrations.add(AddSigningJobDiskImage())

    // 웹 콘솔로 들어온 사람은 스스로 개발자가 된다 (ADR-0056).
    app.migrations.add(AddRoleSetByAdminToUser())

    // 알림을 어디로 받을지. 운영 알림은 스토어가 정하고 개인 알림은 각자 정한다.
    app.migrations.add(AddOperationalAlertsSetting())
    app.migrations.add(AddNotificationPreferencesToUser())
    // 개인 알림을 메일로도 받는다 (ADR-0058).
    app.migrations.add(AddNotifyViaToUser())

    // 워커가 Sparkle 공개키를 알린다 (ADR-0057).
    app.migrations.add(AddWorkerSparklePublicKey())
}

/// 미들웨어 스택.
///
/// 기본 스택을 그대로 두지 않고 새로 쌓는다. Vapor 기본값에는 언제나 JSON 을 주는
/// `ErrorMiddleware` 가 들어 있는데, 웹 콘솔에서 주소를 잘못 치면 사용자가
/// `{"error":true,...}` 를 보게 된다.
///
/// 순서가 중요하다. 오류 처리가 가장 바깥에 있어야 안쪽에서 난 오류를 다 잡는다.
/// 보안 헤더는 그보다 더 바깥에 둔다. 오류 처리가 **만들어낸** 응답에도 헤더가
/// 붙어야 하기 때문이다. 안쪽에 두면 404 화면만 헤더 없이 나간다.
private func configureMiddleware(_ app: Application, config: AppConfig) {
    app.middleware = .init()
    app.middleware.use(
        SecurityHeadersMiddleware(
            storageOrigin: SecurityHeadersMiddleware.storageOrigin(for: config.storage),
            providerOrigin: SecurityHeadersMiddleware.providerOrigin(for: config.oauth)
        )
    )
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
    // **로거를 넘겨야 한다.** 안 넘기면 Soto 는 `loggingDisabled` 를 쓰고, 자격증명을
    // 고르다 실패한 것까지 전부 조용히 삼킨다. 배포된 서버가 왜 스토리지를 못 쓰는지
    // 알아내는 데 그 침묵이 가장 오래 걸렸다 (ADR-0038).
    let client = AWSClient(
        credentialProvider: credentialProvider(for: config, logger: app.logger),
        // 오류만 올린다. 요청 로그(`requestLogLevel`)는 그대로 debug 다. 그쪽까지
        // 올리면 S3 요청마다 줄이 하나씩 쌓인다. 우리가 못 봐서 헤맨 것은 오류 쪽이다.
        options: .init(requestLogLevel: .debug, errorLogLevel: .notice),
        logger: app.logger
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

/// 스토리지에 무엇으로 인증할지 고른다 (ADR-0024).
///
/// 액세스 키를 주면 그것을 쓰고, 안 주면 SDK 기본 체인에 맡긴다. 인스턴스에 붙은
/// 역할로 인증하는 환경(IRSA 계열)은 액세스 키를 아예 발급하지 않으므로, 키를 필수로
/// 두면 서버가 뜨지도 못한다.
///
/// **기본 체인은 아무것도 못 찾아도 여기서 실패하지 않는다.** 그 실패는 스토리지를
/// 처음 쓰는 순간에 나오고, `ArtifactStorage` 가 그때 무엇을 설정해야 하는지 말한다.
private func credentialProvider(
    for config: AppConfig.StorageConfig,
    logger: Logger
) -> CredentialProviderFactory {
    guard let accessKeyID = config.accessKeyID, let secretAccessKey = config.secretAccessKey else {
        // 컨테이너 자격증명 엔드포인트를 먼저 본다. Soto 의 기본 체인이 그것을 모른다
        // (ADR-0038). 주입돼 있지 않으면 `podIdentity` 는 조용히 비켜서고 기본 체인이
        // 이어받는다.
        logger.notice("스토리지 자격증명: 액세스 키가 없어 컨테이너 엔드포인트와 SDK 기본 체인을 씁니다.")
        return .selector(.podIdentity, .default)
    }
    return .static(accessKeyId: accessKeyID, secretAccessKey: secretAccessKey)
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
