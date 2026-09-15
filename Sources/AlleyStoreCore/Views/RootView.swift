import AlleyShared
import SwiftUI

/// 창 하나에 들어가는 전부.
///
/// 서버 주소 입력 → 로그인 → 목록이 한 창에서 이어진다. 단계마다 창을 따로 띄우면
/// 처음 쓰는 사람이 무엇을 하고 있었는지 놓친다.
struct RootView: View {
    @Environment(StoreModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.phase {
            case .needsServer:
                // 주소가 박힌 빌드는 물어볼 것이 없다. 붙는 것을 보여주기만 한다.
                if let server = model.builtInServer {
                    ConnectingView(server: server)
                } else {
                    ServerSetupView()
                }
            case .signedOut(let meta):
                SignInView(meta: meta)
            case .ready(let meta, let user):
                CatalogView(meta: meta, user: user)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await model.restore() }
        .alert(
            "문제가 생겼습니다",
            isPresented: .init(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("확인", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

/// 주소가 박힌 빌드의 첫 화면.
///
/// 조직이 나눠준 앱을 받은 사람에게 주소를 묻는 것은 물어볼 곳이 있는 사람에게만
/// 통한다(ADR-0044). 그래서 여기서는 붙는 동안을 보여주고, 실패했을 때만 손댈
/// 자리를 낸다.
struct ConnectingView: View {
    @Environment(StoreModel.self) private var model
    let server: URL

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if model.isLoading {
                ProgressView()
                Text("연결하는 중입니다...")
                    .foregroundStyle(.secondary)
            } else {
                // 여기 오는 경우는 서버가 내려갔거나 사내망 밖이다. 둘 다 사용자가
                // 할 수 있는 일이 없어서, 무엇에 실패했는지만 정확히 보여준다.
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("스토어에 연결하지 못했습니다")
                    .font(.title2.weight(.semibold))
                Text(server.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("다시 시도") {
                    Task { await model.restore() }
                }
                .keyboardShortcut(.defaultAction)
            }

            Spacer()
        }
        .padding(40)
    }
}

/// 첫 실행 화면. 서버 주소만 받는다.
///
/// 주소를 박지 않고 만든 빌드가 여기로 온다. 이 화면에 조직 이름이 미리 적혀 있으면
/// 안 된다(ADR-0003). 그런 빌드는 어느 조직의 서버에도 그대로 붙는다.
struct ServerSetupView: View {
    @Environment(StoreModel.self) private var model
    @State private var address = ""

    private var normalized: URL? {
        StoreClient.normalize(serverAddress: address)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("스토어 주소를 입력하세요")
                    .font(.title2.weight(.semibold))
                Text("조직에서 안내받은 주소입니다. 담당자에게 물어보면 알려줍니다.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("store.example.com", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { connect() }
                Button("연결", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalized == nil || model.isLoading)
            }

            if model.isLoading {
                ProgressView().controlSize(.small)
            }

            Spacer()
        }
        .padding(40)
    }

    private func connect() {
        guard let normalized else { return }
        Task { await model.connect(to: normalized) }
    }
}

/// 로그인 화면.
struct SignInView: View {
    @Environment(StoreModel.self) private var model
    let meta: StoreMeta

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            StoreBadge(meta: meta)

            Text("조직 구성원에게 배포되는 앱을 받는 곳입니다.")
                .foregroundStyle(.secondary)

            Button("Google 계정으로 로그인") {
                Task { await model.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !meta.allowedEmailDomains.isEmpty {
                Text("로그인 가능한 도메인: \(meta.allowedEmailDomains.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 주소가 박힌 빌드는 갈 데가 없다.
            if model.builtInServer == nil {
                Button("다른 서버에 연결", action: model.forgetServer)
                    .buttonStyle(.link)
            }
        }
        .padding(40)
    }
}

/// 스토어 이름과 로고.
struct StoreBadge: View {
    let meta: StoreMeta

    var body: some View {
        VStack(spacing: 10) {
            if let logo = meta.logoURL.flatMap(URL.init(string:)) {
                AsyncImage(url: logo) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 56, height: 56)
            }
            Text(meta.storeName)
                .font(.title.weight(.semibold))
        }
    }
}
