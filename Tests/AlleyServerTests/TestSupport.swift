import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 테스트가 쓸 설정과 애플리케이션.
///
/// 데이터베이스를 건드리는 테스트는 **개발용 데이터베이스가 아니라 전용 데이터베이스**를
/// 쓴다. 테스트가 끝날 때마다 스키마를 되돌리므로, 개발 중이던 데이터가 날아가면
/// 곤란하기 때문이다.
enum TestSupport {
    /// 필수 항목만 채운 최소 환경. 각 테스트가 여기서 필요한 것만 덧붙인다.
    ///
    /// 여기 있는 값은 전부 가짜다. 실제 조직이나 계정을 가리키지 않는다.
    static let minimalEnvironment: [String: String] = [
        "DATABASE_URL": databaseURL,
        "S3_BUCKET": "alley-artifacts",
        "S3_ACCESS_KEY_ID": "key",
        "S3_SECRET_ACCESS_KEY": "secret",
        "GOOGLE_CLIENT_ID": "client-id",
        "GOOGLE_CLIENT_SECRET": "client-secret",
        "OAUTH_REDIRECT_URI": "https://store.example.com/auth/google/callback",
        "JWT_SECRET": "test-secret",
        "PUBLIC_BASE_URL": "https://store.example.com",
    ]

    /// 테스트 전용 데이터베이스 주소.
    ///
    /// CI 는 서비스 컨테이너를 붙이므로 환경변수로 넘긴다. 로컬은 docker-compose 의
    /// postgres 안에 만든 `alley_test` 를 기본으로 쓴다.
    static var databaseURL: String {
        ProcessInfo.processInfo.environment["TEST_DATABASE_URL"]
            ?? "postgres://alley:alley@localhost:5432/alley_test"
    }

    static func config(overrides: [String: String] = [:]) throws -> AppConfig {
        var environment = minimalEnvironment
        for (key, value) in overrides {
            environment[key] = value
        }
        return try AppConfig.load(from: environment)
    }
}

/// 데이터베이스 없이 도는 애플리케이션.
///
/// 라우팅이나 설정 로딩처럼 데이터베이스를 건드리지 않는 것만 확인할 때 쓴다.
func withConfiguredApp(
    overrides: [String: String] = [:],
    _ body: (Application) async throws -> Void
) async throws {
    let config = try TestSupport.config(overrides: overrides)
    try await withApp { app in
        try await configure(app, config: config)
        try await body(app)
    }
}

/// 데이터베이스를 쓰는 테스트를 한 줄로 세우는 자물쇠.
///
/// Swift Testing 의 `.serialized` 는 **그 스위트 안에서만** 순서를 보장한다.
/// 스위트끼리는 여전히 병렬로 돈다. 우리 테스트는 전부 같은 데이터베이스의 스키마를
/// 올렸다 내리므로, 한 스위트가 되돌리는 동안 다른 스위트가 그 표를 읽으면 깨진다.
///
/// 스위트마다 `.serialized` 를 붙이는 방법은 새 스위트를 만들 때 잊으면 그만이다.
/// 그래서 헬퍼 안에 자물쇠를 둬서 잊을 수 없게 한다.
private actor DatabaseTestLock {
    static let shared = DatabaseTestLock()

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            // 순서를 유지해서 먼저 기다린 쪽이 먼저 들어가게 한다.
            waiting.removeFirst().resume()
        }
    }
}

/// 스키마를 올린 뒤 본문을 돌리고, 끝나면 되돌린다.
///
/// 되돌리기를 `defer` 가 아니라 성공·실패 양쪽에서 명시적으로 부르는 이유는,
/// 실패했을 때 되돌리기까지 실패하면 그 오류가 원래 오류를 덮어버리기 때문이다.
/// 원래 오류를 살려서 던진다.
///
/// 같은 데이터베이스를 쓰는 다른 테스트와 겹치지 않도록 자물쇠를 잡고 돈다.
/// 스위트에 `.serialized` 를 붙일 필요가 없다.
func withMigratedApp(
    overrides: [String: String] = [:],
    _ body: (Application) async throws -> Void
) async throws {
    await DatabaseTestLock.shared.acquire()
    do {
        try await withConfiguredApp(overrides: overrides) { app in
            try await app.autoRevert()
            try await app.autoMigrate()
            do {
                try await body(app)
            } catch {
                try? await app.autoRevert()
                throw error
            }
            try await app.autoRevert()
        }
    } catch {
        await DatabaseTestLock.shared.release()
        throw error
    }
    await DatabaseTestLock.shared.release()
}

// MARK: - 스토리지 대역

/// 테스트가 쓰는 인메모리 아티팩트 스토리지.
///
/// 업로드 완료 통지와 서명 결과 보고는 **스토리지에 파일이 실제로 있는지 확인하는 것**이
/// 핵심 규칙이다. 그 규칙을 검증하려고 매번 MinIO 를 띄우는 대신 여기서 흉내낸다.
/// presigned URL 도 형식만 맞춰 돌려준다. 테스트는 그 URL 로 실제 전송을 하지 않는다.
final class FakeArtifactStorage: ArtifactStoring, @unchecked Sendable {
    struct Unavailable: Error {}

    private let lock = NSLock()
    private var sizes: [String: Int64] = [:]
    /// 스토리지가 죽은 상황을 흉내낸다.
    var isUnavailable = false

    /// 누군가 이 키에 파일을 올렸다고 가정한다.
    func place(key: String, size: Int64 = 1024) {
        lock.lock()
        defer { lock.unlock() }
        sizes[key] = size
    }

    func uploadURL(key: String) async throws -> PresignedURL {
        if isUnavailable { throw Unavailable() }
        return PresignedURL(
            url: "https://storage.example/\(key)?upload=1",
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    func downloadURL(key: String) async throws -> PresignedURL {
        if isUnavailable { throw Unavailable() }
        return PresignedURL(
            url: "https://storage.example/\(key)?download=1",
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    func head(key: String) async throws -> Int64? {
        if isUnavailable { throw Unavailable() }
        // NSLock 은 async 함수 안에서 직접 잠글 수 없다. 잠그는 구간을 동기 함수로 뺀다.
        return size(of: key)
    }

    private func size(of key: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return sizes[key]
    }

    func put(_ data: Data, to key: String, contentType: String?) async throws {
        if isUnavailable { throw Unavailable() }
        place(key: key, size: Int64(data.count))
    }

    func delete(key: String) async throws {
        if isUnavailable { throw Unavailable() }
        // NSLock 은 async 함수 안에서 직접 잠글 수 없다. 잠그는 구간을 동기 함수로 뺀다.
        forget(key)
    }

    private func forget(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        sizes[key] = nil
    }
}

extension Application {
    /// 스토리지를 흉내내는 것으로 바꾸고 그 손잡이를 돌려준다.
    @discardableResult
    func useFakeStorage() -> FakeArtifactStorage {
        let storage = FakeArtifactStorage()
        artifactStorage = storage
        return storage
    }
}

// MARK: - 인증된 요청 만들기

extension Application {
    /// 테스트용 사용자를 만들고 그 사용자로 인증되는 세션 토큰을 함께 준다.
    ///
    /// 로그인 왕복(Google 리다이렉트)은 테스트에서 재현할 수 없으므로 토큰을 직접
    /// 서명한다. 서명 키는 `configure` 가 넣은 것과 같아서, 미들웨어가 실제로 검증하는
    /// 경로를 그대로 지난다.
    func makeUser(
        email: String,
        role: UserRole,
        name: String? = nil
    ) async throws -> (user: User, token: String) {
        let user = User(
            googleSubject: "sub-\(email)",
            email: email,
            name: name ?? email,
            role: role
        )
        try await user.save(on: db)

        let token = try await jwt.keys.sign(
            SessionToken(userID: try user.requireID(), issuedAt: Date(), ttl: 3600)
        )
        return (user, token)
    }
}

extension Application {
    /// 테스트용 워커를 등록하고 토큰을 함께 준다.
    func makeWorker(name: String = "test-worker") async throws -> (worker: Worker, token: String) {
        let token = Worker.generateToken()
        let worker = Worker(name: name, tokenHash: Worker.hash(token: token), createdByID: nil)
        try await worker.save(on: db)
        return (worker, token)
    }
}

extension HTTPHeaders {
    /// Bearer 토큰을 실은 헤더.
    static func bearer(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: token)
        return headers
    }
}

extension HTTPHeaders {
    /// 웹 콘솔처럼 세션 쿠키로 인증하는 요청의 헤더.
    static func sessionCookie(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.cookie = HTTPCookies(dictionaryLiteral: (sessionCookieName, .init(string: token)))
        return headers
    }
}

extension HTTPHeaders {
    /// 브라우저 폼 제출을 흉내낸 헤더.
    ///
    /// 쿠키와 함께 `Origin` 을 붙인다. `Host` 도 맞춰서 출처 검사를 통과하게 한다.
    /// 검사 자체는 별도 테스트에서 확인한다.
    static func form(cookie token: String, origin: String = "http://localhost:8080") -> HTTPHeaders {
        var headers = HTTPHeaders.sessionCookie(token)
        headers.add(name: .origin, value: origin)
        headers.replaceOrAdd(name: .host, value: "localhost:8080")
        headers.contentType = .urlEncodedForm
        return headers
    }
}

// MARK: - 픽스처

extension Application {
    /// 테스트용 앱 하나.
    @discardableResult
    func seedApp(bundleID: String, name: String, owner: User) async throws -> App {
        let record = App(bundleID: bundleID, name: name, ownerID: try owner.requireID())
        try await record.save(on: db)
        // 화면이 오너 이메일을 읽으므로 관계를 채워둔다.
        record.$owner.value = owner
        return record
    }

    /// 테스트용 버전 하나.
    ///
    /// 상태를 직접 넣는다. 전이 규칙을 거치면 픽스처마다 여러 단계를 밟아야 하고,
    /// 그러면 상태 머신 테스트와 화면 테스트가 얽힌다.
    @discardableResult
    func seedVersion(
        appID: UUID,
        short: String,
        build: Int,
        state: VersionState,
        by user: User,
        uploadKind: UploadKind = .unsigned
    ) async throws -> Version {
        let version = Version(
            appID: appID,
            shortVersion: short,
            buildNumber: build,
            uploadKind: uploadKind,
            createdByID: try user.requireID(),
            state: state
        )
        try await version.save(on: db)
        return version
    }
}
