import AlleyShared
import SwiftUI

/// 창 하나에 들어가는 전부.
///
/// 연결 → 로그인 → 목록이 한 창에서 이어진다. 단계마다 창을 따로 띄우면 처음 쓰는
/// 사람이 무엇을 하고 있었는지 놓친다.
struct RootView: View {
    @Environment(StoreModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.phase {
            case .connecting:
                ConnectingView(server: model.builtInServer)
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

/// 붙는 동안, 그리고 붙지 못했을 때.
///
/// **주소를 묻지 않는다.** 조직이 나눠준 앱을 받은 사람에게 주소를 묻는 것은 물어볼
/// 곳이 있는 사람에게만 통한다(ADR-0044). 주소는 빌드할 때 박히고 서명 대상 안에
/// 있어서 받은 사람이 고칠 수도 없다.
struct ConnectingView: View {
    @Environment(StoreModel.self) private var model
    let server: URL?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let server {
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
            } else {
                // 주소를 박지 않고 만든 빌드다. 사람이 고칠 수 있는 것이 아니므로
                // 입력칸을 내지 않는다. 그것을 내면 이 앱은 어느 조직의 서버에도
                // 붙는 앱이 되고, 서명한 조직이 보증하지 않은 곳에 구성원을 보낸다.
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("잘못 만들어진 앱입니다")
                    .font(.title2.weight(.semibold))
                Text("이 앱에는 스토어 주소가 들어 있지 않습니다. 담당자에게 알려주세요.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(40)
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
