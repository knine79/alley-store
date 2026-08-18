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

/// 스키마를 올린 뒤 본문을 돌리고, 끝나면 되돌린다.
///
/// 되돌리기를 `defer` 가 아니라 성공·실패 양쪽에서 명시적으로 부르는 이유는,
/// 실패했을 때 되돌리기까지 실패하면 그 오류가 원래 오류를 덮어버리기 때문이다.
/// 원래 오류를 살려서 던진다.
///
/// **이 함수를 쓰는 스위트에는 `.serialized` 를 붙여야 한다.** 테스트가 병렬로 돌면
/// 한쪽이 스키마를 되돌리는 동안 다른 쪽이 그 표를 읽는다.
func withMigratedApp(
    overrides: [String: String] = [:],
    _ body: (Application) async throws -> Void
) async throws {
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
}
