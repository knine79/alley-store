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
        guard !search.isEmpty else { return model.catalog }
        return model.catalog.filter {
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
                if model.catalog.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "받을 수 있는 앱이 없습니다",
                        systemImage: "shippingbox",
                        description: Text("출시된 앱이 생기면 여기에 나타납니다.")
                    )
                }
            }
        } detail: {
            if let selected = model.apps.first(where: { $0.id == selection }) {
                AppDetailView(app: selected, meta: meta)
            } else {
                ContentUnavailableView(
                    "앱을 고르세요",
                    systemImage: "sidebar.left",
                    description: Text("왼쪽에서 앱을 고르면 자세한 내용이 보입니다.")
                )
            }
        }
        .navigationTitle(meta.storeName)
        .navigationSubtitle(
            model.updateCount > 0 ? "업데이트 \(model.updateCount)개" : ""
        )
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
        // 창을 열어둔 채로 두는 사람이 있다. 목록이 어제 것으로 굳어 있으면
        // 업데이트가 있어도 모른다.
        .task { await model.watchForUpdates() }
        .safeAreaInset(edge: .top) {
            if let update = model.selfUpdate {
                SelfUpdateBanner(app: update)
            }
        }
        .onChange(of: model.apps) { _, _ in
            // 목록이 있는데 오른쪽이 비어 있으면 화면이 절반만 채워진 것처럼 보인다.
            // 사용자가 고르기 전에도 볼 것이 있게 첫 앱을 미리 편다.
            //
            // 목록에 없는 것(스토어 앱 자신)을 고르면 안 된다. 왼쪽에 표시되지 않는
            // 줄이 오른쪽에 펼쳐진다.
            if selection == nil {
                selection = model.catalog.first?.id
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
            AppIcon(app: app, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(model.state(of: app).summary)
                    if let average = app.rating?.displayAverage {
                        Text("★ \(average)")
                    }
                }
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
    let meta: StoreMeta

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

                Divider()
                FeedbackSection(
                    app: app,
                    reviewableVersion: reviewableVersion,
                    allowsAnonymous: meta.allowsAnonymousFeedback
                )

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task(id: app.id) { await model.loadFeedback(for: app) }
    }

    /// 피드백을 남길 수 있는 버전.
    ///
    /// 받아본 버전에만 남길 수 있다(서버 규칙). 앱은 "지금 깔려 있는 것"만 알고
    /// 있으므로, 깔려 있고 그것이 최신 출시본과 같을 때만 폼을 띄운다. 예전 버전을
    /// 깔아둔 사람이 그 버전에 남기는 경로는 웹 콘솔에 있다.
    private var reviewableVersion: VersionDTO? {
        guard let installed = model.installed[app.bundleID],
              let released = app.latestReleasedVersion,
              installed.buildNumber == released.buildNumber
        else {
            return nil
        }
        return released
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(app: app, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.largeTitle.weight(.semibold))
                HStack(spacing: 8) {
                    Text(model.state(of: app).summary)
                    if let rating = app.rating, let average = rating.displayAverage {
                        Text("★ \(average) (\(rating.count))")
                    }
                }
                .foregroundStyle(.secondary)
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

/// 앱 아이콘.
///
/// **아이콘이 없으면 목록이 글자만 남는다.** 그러면 찾는 앱을 이름으로 읽어야 하고,
/// 아이콘으로 알아보던 습관이 통하지 않는다. 그래서 없을 때도 빈자리를 두지 않고
/// 이름 첫 글자로 자리를 채운다. 회색 상자 하나보다 앱마다 달라 보이는 편이 낫다.
struct AppIcon: View {
    let app: AppDTO
    let size: CGFloat

    /// 아이콘이 없을 때 쓸 글자. 한글도 이모지도 한 글자면 된다.
    private var initial: String {
        app.name.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "?"
    }

    /// 이름에서 뽑은 색.
    ///
    /// 무작위로 고르면 목록을 다시 그릴 때마다 색이 바뀐다. 이름에서 뽑으면 같은
    /// 앱은 언제나 같은 색이라 눈이 기억한다.
    private var tint: Color {
        Color(hue: Double(abs(app.bundleID.hashValue) % 360) / 360, saturation: 0.45, brightness: 0.75)
    }

    var body: some View {
        Group {
            if let url = app.iconURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        // 받는 동안과 실패했을 때가 같다. 둘 다 "그림이 없다" 이고,
                        // 자리가 비어 있으면 줄 높이가 흔들린다.
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            tint
            Text(initial)
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// 스토어 앱 자신에게 새 버전이 있을 때 위에 뜨는 줄.
///
/// 목록 안에 섞어두면 자기 자신을 업데이트하는 것이 다른 앱을 받는 것과 같아 보인다.
/// 실제로는 앱이 종료되고 다시 뜨므로 미리 알려야 한다.
struct SelfUpdateBanner: View {
    @Environment(StoreModel.self) private var model
    let app: AppDTO

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(app.name) 새 버전이 있습니다")
                    .font(.callout.weight(.medium))
                if let version = app.latestReleasedVersion {
                    Text("업데이트하면 앱이 다시 시작합니다 · \(version.shortVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if let progress = model.progress[app.id] {
                switch progress {
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 80).controlSize(.small)
                case .verifying, .installing:
                    ProgressView().controlSize(.small)
                }
            } else {
                Button("업데이트") {
                    Task { await model.updateSelf(app) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
