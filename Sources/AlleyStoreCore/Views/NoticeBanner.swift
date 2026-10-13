import SwiftUI

/// 창 위쪽에 붙는 알림 줄. 업데이트 배너와 연결 배너가 같은 모양을 쓴다.
///
/// 배경은 칠하지 않는다. 상태 색으로 칠하면 창 위쪽이 통째로 빨갛거나 파래져서 목록과
/// 상세보다 배너가 먼저 읽힌다. 대신 색 원 아이콘과 왼쪽 띠로 상태를 구분한다. 예전
/// 업데이트 배너는 회색 바탕에 작은 아이콘 하나뿐이라 있는 줄도 몰랐다.
struct NoticeBanner<Accessory: View>: View {
    /// 원 안에 그릴 그림.
    let symbol: String
    let tint: Color
    let title: String
    var caption: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

extension NoticeBanner where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, caption: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, caption: caption) { EmptyView() }
    }
}

/// 서버와의 연결이 끊겼거나 다시 붙었을 때 뜨는 줄 (`StoreModel.connectionNotice`).
///
/// 끊긴 배너는 다시 붙을 때까지 남는다. 사라지면 목록이 낡은 채로 굳어 있다는 것을
/// 알 길이 없다. 다시 붙은 배너는 잠깐 떴다가 사라진다.
struct ConnectionBanner: View {
    @Environment(StoreModel.self) private var model

    var body: some View {
        // `Group` 이면 배너가 없을 때 붙을 뷰가 없어 아래 `onChange` 가 걸리지 않는다.
        VStack(spacing: 0) {
            banner
        }
        // 화면을 보지 않는 사람은 배너가 떴는지 모른다. 끊김과 회복을 소리로도 알린다.
        .onChange(of: model.connectionNotice) { _, notice in
            switch notice {
            case .lost: AccessibilityNotification.Announcement("스토어에 연결할 수 없습니다").post()
            case .restored: AccessibilityNotification.Announcement("다시 연결되었습니다").post()
            case nil: break
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch model.connectionNotice {
        case .lost:
            NoticeBanner(
                symbol: "wifi.slash",
                tint: .red,
                title: "스토어에 연결할 수 없습니다",
                caption: "네트워크 연결을 확인해 주세요. 연결되면 자동으로 다시 붙습니다."
            ) {
                if model.isReconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("다시 시도") {
                        Task { await model.reconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        case .restored:
            NoticeBanner(symbol: "checkmark", tint: .green, title: "다시 연결되었습니다")
                .transition(.move(edge: .top).combined(with: .opacity))
        case nil:
            EmptyView()
        }
    }
}
