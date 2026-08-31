import AlleyShared
import Vapor

func routes(_ app: Application) throws {
    // 오케스트레이터가 찌르는 헬스체크. 인증을 걸지 않는다.
    app.get(APIPath.health.pathComponents) { _ in
        HealthResponse(status: "ok", apiVersion: APIPath.currentAPIVersion)
    }

    // 클라이언트 부트스트랩 지점.
    // 스토어 앱은 서버 도메인만 알고 여기서 브랜딩과 인증 설정을 받아간다.
    app.get(APIPath.meta.pathComponents) { req async throws -> StoreMeta in
        // 브랜딩과 허용 도메인은 관리자가 화면에서 바꾸므로 요청 시점에 읽는다.
        // 커스텀 URL 스킴만 환경변수에서 온다 (ADR-0011).
        try await req.storeSettings()
            .toMeta(callbackURLScheme: req.application.alleyConfig.store.callbackURLScheme)
    }

    try app.register(collection: AuthController())
    try app.register(collection: AppController())
    try app.register(collection: VersionController())
    try app.register(collection: AdminController())
    try app.register(collection: WorkerController())
    try app.register(collection: DeployTokenController())

    // 웹 콘솔. JSON API 보다 뒤에 등록해서 경로가 겹칠 때 API 가 이긴다.
    try app.register(collection: WebController())
    try app.register(collection: AppPagesController())
    try app.register(collection: VersionPagesController())
    try app.register(collection: AdminPagesController())
}

struct HealthResponse: Content {
    var status: String
    var apiVersion: Int
}

// AlleyShared 는 Vapor 에 의존하지 않는다. SwiftUI 스토어 앱도 같은 타입을 쓰기 때문이다.
// 그래서 HTTP 직렬화 능력은 서버 쪽에서 덧붙인다.
extension StoreMeta: Content {}
