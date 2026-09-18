import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        do {
            try await configure(app)
            // 종료 신호를 직접 듣는다. serve 명령도 같은 신호를 듣지만 알려주지
            // 않으므로, 긴 폴링을 깨우는 일은 여기서 시작한다 (ADR-0052).
            // 프로세스 전역을 건드리는 일이라 서버를 실제로 띄우는 이 자리에만 둔다.
            app.shutdownSignal.listenForTermination()
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
