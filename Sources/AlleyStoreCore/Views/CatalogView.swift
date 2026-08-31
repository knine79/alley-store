import AlleyShared
import SwiftUI

/// 앱 목록과 상세.
///
/// 목록만으로 대부분의 일이 끝나야 한다. 여기 오는 사람은 대개 하나를 받으러 온다.
/// 그래서 설치 버튼을 상세로 들어가지 않고 목록에서 바로 누를 수 있게 뒀다.
struct CatalogView: View {
    @Environment(StoreModel.self) private var model
    let meta: StoreMeta
    let user: UserDTO

    @State private var selection: AppDTO.ID?
    @State private var search = ""

    private var visible: [AppDTO] {
        guard !search.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(visible, selection: $selection) { app in
                AppRow(app: app)
                    .tag(app.id)
            }
            .searchable(text: $search, prompt: "앱 검색")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if model.apps.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "받을 수 있는 앱이 없습니다",
                        systemImage: "shippingbox",
                        description: Text("출시된 앱이 생기면 여기에 나타납니다.")
                    )
                }
            }
        } detail: {
            if let selected = model.apps.first(where: { $0.id == selection }) {
                AppDetailView(app: selected)
            } else {
                ContentUnavailableView(
                    "앱을 고르세요",
                    systemImage: "sidebar.left",
                    description: Text("왼쪽에서 앱을 고르면 자세한 내용이 보입니다.")
                )
            }
        }
        .navigationTitle(meta.storeName)
        .toolbar {
            ToolbarItem(placement: .status) {
                if let status = model.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("새로 고침", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
            ToolbarItem {
                Menu {
                    Text(user.email)
                    Divider()
                    Button("로그아웃", action: model.signOut)
                    Button("다른 서버에 연결", action: model.forgetServer)
                } label: {
                    Label(user.name, systemImage: "person.crop.circle")
                }
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.apps) { _, apps in
            // 목록이 있는데 오른쪽이 비어 있으면 화면이 절반만 채워진 것처럼 보인다.
            // 사용자가 고르기 전에도 볼 것이 있게 첫 앱을 미리 편다.
            if selection == nil {
                selection = apps.first?.id
            }
        }
    }
}

/// 목록의 한 줄.
struct AppRow: View {
    @Environment(StoreModel.self) private var model
    let app: AppDTO

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body.weight(.medium))
                Text(model.state(of: app).summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            InstallButton(app: app)
        }
        .padding(.vertical, 2)
    }
}

/// 설치·업데이트 버튼. 받는 동안에는 진행률이 된다.
struct InstallButton: View {
    @Environment(StoreModel.self) private var model
    let app: AppDTO

    var body: some View {
        if let progress = model.progress[app.id] {
            switch progress {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 60)
                    .controlSize(.small)
            case .verifying, .installing:
                ProgressView()
                    .controlSize(.small)
            }
        } else if app.latestReleasedVersion != nil {
            Button(model.state(of: app).actionTitle) {
                Task { await model.install(app) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// 앱 하나의 상세.
struct AppDetailView: View {
    @Environment(StoreModel.self) private var model
    let app: AppDTO

    private var installed: InstalledApp? {
        model.installed[app.bundleID]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let summary = app.summary {
                    Text(summary).font(.title3)
                }
                if let description = app.description {
                    Text(description).textSelection(.enabled)
                }

                Divider()

                LabeledContent("번들 ID") {
                    Text(app.bundleID).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let version = app.latestReleasedVersion {
                    LabeledContent("최신 출시본") {
                        Text("\(version.shortVersion) (빌드 \(version.buildNumber))")
                    }
                    if let size = version.fileSize {
                        LabeledContent("크기") {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                    }
                    if let minimum = version.minimumOSVersion {
                        LabeledContent("필요한 macOS") { Text(minimum) }
                    }
                }
                if let installed {
                    LabeledContent("설치된 위치") {
                        Text(installed.location.path)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }

                if let notes = app.latestReleasedVersion?.releaseNotes, !notes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("릴리즈 노트").font(.headline)
                        Text(notes).textSelection(.enabled)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.largeTitle.weight(.semibold))
                Text(model.state(of: app).summary).foregroundStyle(.secondary)
            }
            Spacer()
            if app.latestReleasedVersion == nil {
                Text("출시본 없음").foregroundStyle(.secondary)
            } else {
                InstallButton(app: app)
                    .controlSize(.large)
            }
        }
    }
}
