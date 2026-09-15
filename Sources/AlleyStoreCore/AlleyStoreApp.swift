import SwiftUI

/// 스토어 앱 그 자체.
///
/// 창 하나짜리 앱이다. 사내 앱을 받고 업데이트하는 것이 전부라 문서 기반으로 만들
/// 이유가 없다.
///
/// `@main` 을 여기 붙이지 않고 실행 타깃의 `main.swift` 가 이 타입을 띄운다.
/// 앱 코드가 라이브러리에 있어야 테스트가 그대로 임포트할 수 있다.
public struct AlleyStoreApp: App {
    @State private var model = StoreModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 새 창을 여러 개 띄울 이유가 없다. 상태가 하나뿐이라 창만 늘어난다.
            CommandGroup(replacing: .newItem) {}

            // 맥 앱이 자기를 갱신하는 자리는 앱 메뉴다. 사람들이 거기서 찾는다.
            // 목록 위의 배너는 새 버전이 있을 때만 나오므로, 없을 때 "지금 최신인가"
            // 를 확인할 길이 그것 말고는 없었다.
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인") {
                    Task { await model.checkForUpdatesNow() }
                }
                .disabled(model.isLoading)
            }
        }
    }
}
