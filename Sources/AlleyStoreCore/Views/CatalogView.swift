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

    init(meta: StoreMeta, user: UserDTO, selection: AppDTO.ID? = nil) {
        self.meta = meta
        self.user = user
        // 처음 고른 앱을 밖에서 줄 수 있게 한다. 화면을 서버 없이 그려볼 때 쓴다.
        _selection = State(initialValue: selection)
    }

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
                } label: {
                    Label(user.name, systemImage: "person.crop.circle")
                }
            }
        }
        // 목록을 읽고, 스토어 앱 자신의 새 버전이 있으면 그 자리에서 갈아끼운다.
        //
        // 읽기만 하면 자기 업데이트는 아래 주기의 첫 차례, 즉 30분 뒤에야 적용된다.
        // 그 사이 사람은 배너만 보고, 창을 닫으면 그 차례마저 오지 않는다. 자기
        // 업데이트는 묻지 않는다는 것이 원래 뜻이다 (`watchForUpdates`).
        .task { await model.checkForUpdatesNow() }
        // 창을 열어둔 채로 두는 사람이 있다. 목록이 어제 것으로 굳어 있으면
        // 업데이트가 있어도 모른다.
        .task { await model.watchForUpdates() }
        // 방금 한 일을 아래쪽 가운데에 잠깐 띄운다 (`StoreModel.announce`). 툴바 상태 칸에
        // 회색 글자로 두면 눈에 안 띄고, 사라지지 않아 언제 일인지 알 수 없었다. 위쪽에
        // 띄우면 상세의 앱 이름을 가린다.
        .overlay(alignment: .bottom) {
            if let status = model.statusMessage {
                StatusToast(message: status)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.statusMessage)
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
                // 설치 상태는 적지 않는다. 오른쪽 버튼(설치·업데이트·열기)이 이미 말한다.
                // 그 자리에는 누가 만들었는지를 둔다.
                HStack(spacing: 6) {
                    if let developers = app.developerNames, !developers.isEmpty {
                        Text(developers.joined(separator: ", ")).lineLimit(1)
                    }
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
    /// 띄울 확인. 있으면 창이 떠 있다.
    @State private var pendingWarning: ReinstallWarning?

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
            let state = model.state(of: app)
            Button(state.actionTitle) {
                if state.opensInstalledApp {
                    model.open(app)
                } else {
                    install(state)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // 깔린 것을 덮어쓰기 전에 한 번 묻는다. 개발자가 직접 넣은 빌드일 때가
            // 많고, 덮어쓰면 그 빌드는 스토어 어디에도 없다.
            .alert(
                pendingWarning?.title ?? "",
                isPresented: Binding(
                    get: { pendingWarning != nil },
                    set: { if !$0 { pendingWarning = nil } }
                ),
                presenting: pendingWarning
            ) { _ in
                Button("다시 설치", role: .destructive) {
                    Task { await model.install(app) }
                }
                Button("취소", role: .cancel) {}
            } message: { warning in
                Text(warning.message(installed: installedLabel, released: releasedLabel))
            }
            .contextMenu {
                // 최신인데 앱이 깨졌을 때 고칠 길이다. 버튼이 "열기" 가 되면서
                // 다시 받는 길이 눈앞에서 사라져서 여기 남긴다.
                if state.opensInstalledApp {
                    Button("다시 설치") { install(state) }
                }
            }
        }
    }

    /// 덮어쓰는 경우면 먼저 묻고, 아니면 바로 받는다.
    private func install(_ state: InstallState) {
        if let warning = state.reinstallWarning {
            pendingWarning = warning
        } else {
            Task { await model.install(app) }
        }
    }

    private var installedLabel: String {
        model.installed[app.bundleID].map(Self.label) ?? "설치된 버전"
    }

    /// 두 라벨 모두 번들에 적힌 값을 쓴다 (ADR-0066). 깔린 쪽은 번들 값, 출시본은 스토어
    /// 번호로 적으면 "빌드 250 → 빌드 1" 처럼 내려가는 것으로 읽힌다.
    private var releasedLabel: String {
        app.latestReleasedVersion.map { version in
            "\(version.shortVersion) (빌드 \(version.bundleVersion ?? String(version.buildNumber)))"
        } ?? "스토어의 출시본"
    }

    private static func label(_ app: InstalledApp) -> String {
        let version = app.shortVersion ?? "알 수 없는 버전"
        return app.bundleVersion.map { "\(version) (빌드 \($0))" } ?? version
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

                // 위쪽 한 줄에도 있지만, 앱 정보를 훑는 사람은 여기서 찾는다.
                if let developers = app.developerNames, !developers.isEmpty {
                    LabeledContent("개발자") {
                        Text(developers.joined(separator: ", ")).textSelection(.enabled)
                    }
                }
                LabeledContent("번들 ID") {
                    Text(app.bundleID).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let version = app.latestReleasedVersion {
                    LabeledContent("최신 출시본") {
                        // 번들에 적힌 값을 보인다. 스토어의 빌드 번호는 번들과 다를 수 있다 (ADR-0066).
                        Text("\(version.shortVersion) (빌드 \(version.bundleVersion ?? String(version.buildNumber)))")
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
        // 빌드 번호를 직접 견주지 않는다. 스토어의 빌드 번호와 번들의 값은 다를 수 있다
        // (ADR-0066). 목록의 "최신" 표시와 같은 판단을 쓴다.
        guard model.state(of: app) == .upToDate, let released = app.latestReleasedVersion else {
            return nil
        }
        return released
    }

    /// "김개발, 이동료 · 다운로드 1,234회 · ★ 4.6 (12)". 아는 것만 잇는다.
    private var byline: String? {
        var parts: [String] = []
        if let developers = app.developerNames, !developers.isEmpty {
            parts.append(developers.joined(separator: ", "))
        }
        if let count = app.downloadCount {
            parts.append("다운로드 \(count.formatted())회")
        }
        if let rating = app.rating, let average = rating.displayAverage {
            parts.append("★ \(average) (\(rating.count))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(app: app, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.largeTitle.weight(.semibold))
                // 누가 만들었고 얼마나 받아갔는지를 이름 바로 아래에 둔다. 받을지 말지를
                // 정하는 사람이 가장 먼저 보는 것이 이 둘이다. 설치 상태는 적지 않는다.
                // 오른쪽 버튼이 이미 말한다.
                if let byline {
                    Text(byline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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
                if let blocker = model.selfUpdateBlocker {
                    // 누를 버튼을 주지 않는다. 눌러도 할 수 있는 일이 없다.
                    Text(blocker.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let version = app.latestReleasedVersion {
                    Text("업데이트하면 앱이 다시 시작합니다 · \(version.shortVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if model.selfUpdateBlocker != nil {
                EmptyView()
            } else if let progress = model.progress[app.id] {
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

/// 방금 한 일을 알리는 한 줄. 잠깐 떴다가 사라진다.
struct StatusToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            // 알림이 떠 있는 동안에도 아래를 누를 수 있어야 한다.
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
    }
}

