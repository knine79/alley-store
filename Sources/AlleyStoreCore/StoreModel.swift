import AlleyShared
import AppKit
import Foundation
import Observation

/// 앱 전체가 보는 상태.
///
/// 화면은 이 하나만 읽는다. 붙는 중, 로그인 전, 목록을 보는 중이 모두 같은 창에서
/// 이어지므로 상태를 나눠 들고 있으면 어느 것이 진짜인지 흐려진다.
@MainActor
@Observable
final class StoreModel {
    /// 지금 앱이 서 있는 자리.
    enum Phase: Equatable {
        /// 아직 서버에 붙지 못했다. 처음 뜬 직후이거나 연결에 실패한 뒤다.
        case connecting
        /// 서버에 붙었지만 로그인하지 않았다.
        case signedOut(StoreMeta)
        case ready(StoreMeta, UserDTO)
    }

    /// 앱 하나를 설치하는 동안의 진행 상황.
    enum Progress: Equatable {
        case downloading(Double)
        case verifying
        case installing
    }

    private(set) var phase: Phase = .connecting
    private(set) var apps: [AppDTO] = []
    private(set) var installed: [String: InstalledApp] = [:]
    private(set) var isLoading = false
    /// 브라우저에서 로그인이 끝나기를 기다리는 중인지.
    ///
    /// 로그인은 앱 밖에서 일어난다. 이것이 없으면 브라우저를 닫아버린 사람이 앱에서
    /// 아무 표시도 보지 못하고, 무엇을 다시 눌러야 하는지도 모른다.
    private(set) var isWaitingForBrowser = false
    /// 앱별 진행 상황. 목록에서 여러 개를 동시에 받을 수 있다.
    private(set) var progress: [UUID: Progress] = [:]

    var errorMessage: String?
    /// 방금 무엇을 했는지 알리는 한 줄. 설치가 끝났다는 것 정도.
    ///
    /// **잠깐 보였다가 사라진다** (`announce`). 예전에는 다음 설치를 시작할 때까지
    /// 툴바에 남아서, 한참 뒤에 본 사람은 그것이 언제 일인지 알 수 없었다.
    private(set) var statusMessage: String?
    private var statusDismissal: Task<Void, Never>?

    /// 알림이 머무는 시간. 한 줄을 읽기에 충분하고, 다음 일을 가리지 않을 만큼.
    static let statusDuration: Duration = .seconds(4)

    /// 알림을 띄우고 잠시 뒤 거둔다. 연달아 오면 마지막 것만 남기고 시간을 다시 잰다.
    func announce(_ message: String) {
        statusDismissal?.cancel()
        statusMessage = message
        statusDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.statusDuration)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    /// 이 빌드에 박혀 나온 서버 주소.
    ///
    /// **이 앱은 붙을 곳을 하나만 안다.** 주소는 빌드할 때 `Info.plist` 에 박히고,
    /// 그 파일은 서명 대상 안에 있어서 받은 사람이 고치면 서명이 깨진다
    /// (ADR-0044, ADR-0046).
    ///
    /// 옵셔널로 남겨둔 것은 주소 없이 만든 빌드가 물리적으로 가능하기 때문이다.
    /// 그때는 물어보지 않고 "잘못 만든 빌드" 라고 말한다. 물어보면 그 빌드는 어느
    /// 조직의 서버에도 붙는 앱이 되고, 서명한 조직이 보증하지 않은 곳에 구성원을
    /// 보내게 된다.
    let builtInServer: URL?

    private let credentials = Credentials()
    private var client: StoreClient?

    init(builtInServer: URL? = BuiltInServer.url) {
        self.builtInServer = builtInServer
    }

    // MARK: - 시작

    /// 박힌 주소로 붙고, 저장된 토큰으로 되돌아간다.
    func restore() async {
        guard let builtInServer else { return }
        await connect(to: builtInServer)
    }

    /// 서버에 붙는다.
    ///
    /// `/meta` 가 돌아오면 Alley 서버가 맞다. 이름과 색과 허용 도메인을 여기서 받는다.
    func connect(to server: URL) async {
        isLoading = true
        defer { isLoading = false }

        var probe = StoreClient(server: server)
        do {
            let meta = try await probe.meta()
            probe.token = credentials.token(for: server)
            client = probe

            if probe.token != nil {
                await loadSession(meta: meta)
            } else {
                phase = .signedOut(meta)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 로그인

    func signIn() async {
        guard let client, case .signedOut(let meta) = phase else { return }

        isWaitingForBrowser = true
        defer { isWaitingForBrowser = WebSignIn.shared.isWaiting }

        do {
            let (code, verifier) = try await WebSignIn.shared.authorize(
                server: client.server,
                callbackScheme: meta.callbackURLScheme
            )
            let exchanged = try await client.exchange(code: code, verifier: verifier)
            credentials.setToken(exchanged.token, for: client.server)
            self.client?.token = exchanged.token

            phase = .ready(meta, exchanged.user)
            await refresh()
        } catch WebSignIn.SignInError.cancelled {
            // 사용자가 창을 닫은 것뿐이다. 오류로 띄우지 않는다.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 브라우저에서 하던 로그인을 그만둔다.
    func cancelSignIn() {
        WebSignIn.shared.cancel()
    }

    func signOut() {
        guard let client else { return }
        credentials.setToken(nil, for: client.server)
        self.client?.token = nil
        apps = []

        if case .ready(let meta, _) = phase {
            phase = .signedOut(meta)
        }
    }

    /// 저장된 토큰이 아직 쓸 수 있는지 확인한다.
    private func loadSession(meta: StoreMeta) async {
        guard let client else { return }
        do {
            let user = try await client.currentUser()
            phase = .ready(meta, user)
            await refresh()
        } catch StoreClient.ClientError.unauthorized {
            // 만료된 토큰은 지운다. 남겨두면 요청마다 401 을 받는다.
            credentials.setToken(nil, for: client.server)
            self.client?.token = nil
            phase = .signedOut(meta)
        } catch {
            errorMessage = error.localizedDescription
            phase = .signedOut(meta)
        }
    }

    // MARK: - 목록

    func refresh() async {
        guard let client, case .ready = phase else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            // 설치 현황은 디스크를 봐야 안다. 목록과 함께 갱신해야 화면이 어긋나지 않는다.
            async let remote = client.apps()
            let scanned = InstalledApps.scan()
            apps = try await remote
                .map { Self.resolvingIcon($0, against: client.server) }
                .sorted { $0.name < $1.name }
            installed = scanned
        } catch StoreClient.ClientError.unauthorized {
            signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 아이콘 주소가 상대 주소면 서버 주소에 붙인다.
    ///
    /// 예전 서버는 `/apps/<id>/icon.png` 를 그대로 내려준다. `URL(string:)` 은 그것을
    /// 호스트 없는 주소로 만들고, `AsyncImage` 는 아무 데도 가지 않은 채 빈 자리를 남긴다.
    /// 지금 서버는 절대 주소를 주므로 이것은 예전 서버에 붙었을 때의 대비다.
    nonisolated static func resolvingIcon(_ app: AppDTO, against server: URL) -> AppDTO {
        guard let icon = app.iconURL, icon.hasPrefix("/"), !icon.hasPrefix("//"),
              let absolute = URL(string: icon, relativeTo: server)?.absoluteString
        else { return app }
        var resolved = app
        resolved.iconURL = absolute
        return resolved
    }

    // MARK: - 피드백

    /// 지금 상세를 보고 있는 앱의 피드백. 앱을 고를 때마다 새로 읽는다.
    private(set) var feedback: [FeedbackDTO] = []
    private(set) var isLoadingFeedback = false

    /// 앱 하나의 피드백을 읽는다.
    ///
    /// 목록을 그릴 때 앱마다 미리 읽지 않는다. 대부분은 열어보지 않는 앱이고,
    /// 목록 한 번에 요청이 앱 수만큼 나가면 서버가 그것부터 힘들어진다.
    func loadFeedback(for app: AppDTO) async {
        guard let client else { return }
        feedback = []
        isLoadingFeedback = true
        defer { isLoadingFeedback = false }

        do {
            feedback = try await client.feedback(ofApp: app.id)
        } catch StoreClient.ClientError.unauthorized {
            signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 별점과 글을 남긴다.
    func submitFeedback(
        rating: Int?,
        body: String?,
        isAnonymous: Bool,
        versionID: UUID,
        app: AppDTO
    ) async -> Bool {
        guard let client else { return false }

        do {
            _ = try await client.submitFeedback(
                SubmitFeedbackRequest(rating: rating, body: body, isAnonymous: isAnonymous),
                versionID: versionID
            )
            await loadFeedback(for: app)
            // 평균이 바뀌었으므로 목록도 다시 읽는다.
            await refresh()
            announce("\(app.name)에 피드백을 남겼습니다.")
            return true
        } catch StoreClient.ClientError.unauthorized {
            signOut()
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func state(of app: AppDTO) -> InstallState {
        InstallState.compare(
            installed: installed[app.bundleID],
            released: app.latestReleasedVersion
        )
    }

    // MARK: - 업데이트 확인

    /// 배경에서 목록을 다시 읽는 주기.
    ///
    /// 사내 앱은 하루에 몇 번 올라온다. 자주 물어봐야 얻을 것이 없고, 창을 열어둔
    /// 사람마다 요청이 나간다.
    static let refreshInterval: Duration = .seconds(30 * 60)

    /// 업데이트가 있는 앱 수. 창 제목에 붙인다.
    var updateCount: Int {
        apps.filter { state(of: $0) == .updateAvailable }.count
    }

    /// 목록에 보여줄 앱들.
    ///
    /// 두 가지를 뺀다.
    ///
    /// **출시본이 없는 앱.** 서버는 개발자와 관리자에게 준비 중인 앱까지 내려준다.
    /// 웹 콘솔은 그것을 보여줘야 하지만(올린 사람이 상태를 봐야 한다) 여기는 앱을
    /// **받는** 자리다. 받을 수 없는 줄이 서 있으면 눌러도 아무 일이 없고, 목록이
    /// 무엇을 하는 곳인지 흐려진다.
    ///
    /// **스토어 앱 자신.** 남겨두면 "설치됨" 으로 늘 한 칸을 차지하고, 새 버전이
    /// 있을 때는 받기 버튼이 목록 안에 생긴다. 그런데 자기를 갈아끼우는 것은 다른
    /// 앱을 받는 것과 달라서 - 앱이 종료되고 다시 뜬다 - 같은 자리에 같은 모양으로
    /// 두면 안 된다. 그 일은 위쪽 배너가 맡는다(`selfUpdate`, `SelfUpdateBanner`).
    var catalog: [AppDTO] {
        apps.filter { $0.latestReleasedVersion != nil && !isSelf($0) }
    }

    /// 이 앱이 나 자신인가.
    ///
    /// **서버가 말해주는 것을 먼저 믿는다.** 번들 ID 로 견주는 것은 관리자가 스토어
    /// 앱의 번들 ID 를 바꾸는 순간 어긋난다. 이미 깔린 스토어 앱들은 자기를 못
    /// 알아보고 새 스토어 앱을 목록에 세운다. 로컬에서 만든 빌드를 다른 서버에
    /// 붙일 때도 그렇다 (`AppDTO.isStoreApp`).
    ///
    /// 그 표시를 모르는 예전 서버에는 번들 ID 로 견준다. 번들 밖에서 실행할
    /// 때(`swift run`)는 번들 ID 가 없어 아무것도 빠지지 않는다. 개발 중에는 그
    /// 편이 낫다.
    func isSelf(_ app: AppDTO) -> Bool {
        if let flag = app.isStoreApp { return flag }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return app.bundleID == bundleID
    }

    /// 스토어 앱 자신의 새 버전. 없으면 nil.
    ///
    /// 자기 자신도 이 스토어로 배포한다(설계 문서 §5.4). 다른 앱과 같은 방식으로
    /// 찾되, 설치는 실행 중인 자기를 갈아끼우는 일이라 경로가 다르다.
    var selfUpdate: AppDTO? {
        guard let entry = apps.first(where: isSelf) else { return nil }
        return state(of: entry) == .updateAvailable ? entry : nil
    }

    /// 창이 열려 있는 동안 주기적으로 목록을 다시 읽고, 자기 새 버전이 있으면 스스로
    /// 갈아끼운다.
    ///
    /// **자기 업데이트는 묻지 않는다.** 스토어 앱이 낡으면 다른 앱을 받는 길 자체가
    /// 낡는다. 받는 사람은 그 사실을 알 방법이 없고, 배너를 띄워둬도 "나중에" 가
    /// 쌓인다. 다른 앱은 사람이 골라 받는 것이라 그대로 두고, 스토어 앱만 그렇게 한다.
    ///
    /// 다만 **다른 일이 돌고 있으면 건드리지 않는다.** 앱을 받는 중에 스토어가 스스로
    /// 종료하면 받던 것이 사라진다. 그때는 다음 차례로 미룬다.
    func watchForUpdates() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            guard !Task.isCancelled else { return }
            await refresh()
            await applySelfUpdateIfIdle()
        }
    }

    /// 사람이 "업데이트 확인" 을 눌렀을 때. 지금 바로 읽고, 있으면 갈아끼운다.
    ///
    /// 주기를 기다리지 않고 확인할 길이 있어야 한다. 새 버전이 나온 것을 다른 데서
    /// 듣고 온 사람에게 "30분 뒤에 뜹니다" 는 답이 아니다.
    func checkForUpdatesNow() async {
        await refresh()
        await applySelfUpdateIfIdle()
    }

    /// 지금 도는 번들을 제자리에서 갈아끼울 수 없는 까닭. 갈아끼울 수 있으면 nil.
    ///
    /// 앱이 도는 동안 자리가 바뀌지 않으므로 한 번만 본다. 번들 밖(`swift run`)이면
    /// 어차피 교체하지 않으니 막을 것도 없다 (`SelfUpdate.blocker`).
    let selfUpdateBlocker: SelfUpdate.Blocker? = SelfUpdate.currentBundle()
        .flatMap { SelfUpdate.blocker(for: $0) }

    /// 다른 일이 없을 때만 자기를 갈아끼운다.
    ///
    /// 못 바꾸는 자리면 시도하지 않는다. 시도하면 앱이 종료됐다가 옛 번들로 다시 뜨고,
    /// 주기마다 그것을 되풀이한다. 그 자리에서는 배너가 까닭과 할 일을 안내한다.
    private func applySelfUpdateIfIdle() async {
        guard selfUpdateBlocker == nil, progress.isEmpty, let update = selfUpdate else { return }
        await updateSelf(update)
    }

    /// 스토어 앱 자신을 새 버전으로 갈아끼운다.
    ///
    /// 받아서 검증하는 데까지는 다른 앱과 같다. 다른 점은 마지막에 스스로 종료한다는
    /// 것이다. 이 함수가 돌아오면 앱은 곧 사라진다.
    func updateSelf(_ app: AppDTO) async {
        guard let client, let version = app.latestReleasedVersion else { return }
        guard progress[app.id] == nil else { return }
        // 받기 전에 멈춘다. 다 받고 나서 못 놓는다고 하면 받은 것이 헛일이 된다.
        if let blocker = selfUpdateBlocker {
            errorMessage = blocker.message
            return
        }

        errorMessage = nil
        progress[app.id] = .downloading(0)
        defer { progress[app.id] = nil }

        do {
            let ticket = try await client.downloadTicket(versionID: version.id)
            guard let url = URL(string: ticket.downloadURL) else {
                throw StoreClient.ClientError.malformedResponse
            }

            let archive = try await Downloader.download(from: url) { [weak self] fraction in
                Task { @MainActor in self?.progress[app.id] = .downloading(fraction) }
            }

            progress[app.id] = .verifying
            let unpacked = try await Installer().prepare(
                archive: archive,
                expectedSHA256: ticket.sha256
            )

            progress[app.id] = .installing
            // 여기서부터는 되돌릴 수 없다. 앱이 곧 종료된다.
            try SelfUpdate.replaceAndRelaunch(with: unpacked)
        } catch StoreClient.ClientError.unauthorized {
            signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 설치

    /// 깔려 있는 앱을 연다.
    ///
    /// 번들 ID 로 찾지 않고 스캔한 자리를 연다. 같은 앱이 두 곳에 있으면 번들 ID
    /// 로는 Launch Services 가 고른 쪽이 뜨는데, 이 화면이 "설치된 위치" 로 보여주는
    /// 것은 스캔한 쪽이다. 보여준 것과 다른 것을 열면 안 된다.
    ///
    /// completion handler 판을 쓰지 않는다. AppKit 이 그 클로저를 Launch Services
    /// 큐에서 부르는데, SDK 가 클로저를 `@Sendable` 로 들여오지 않으면 메인 액터
    /// 격리를 물려받아 입구에서 트랩이 난다. macOS 15 SDK 로 빌드한 배포본이
    /// 그렇게 죽었다 (#37).
    func open(_ app: AppDTO) async {
        guard let location = installed[app.bundleID]?.location else { return }
        statusDismissal?.cancel()
        statusMessage = nil
        errorMessage = nil
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: location,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } catch {
            errorMessage = "\(app.name) 을(를) 열지 못했습니다.\n\(error.localizedDescription)"
        }
    }

    /// 최신 출시본을 받아 설치한다.
    func install(_ app: AppDTO) async {
        guard let client, let version = app.latestReleasedVersion else { return }
        guard progress[app.id] == nil else { return }
        // 끝난 뒤에는 새것이 깔려 있어서 무엇을 했는지(올렸나, 내렸나) 알 수 없다.
        let before = state(of: app)

        statusDismissal?.cancel()
        statusMessage = nil
        errorMessage = nil
        progress[app.id] = .downloading(0)
        defer { progress[app.id] = nil }

        do {
            let ticket = try await client.downloadTicket(versionID: version.id)
            guard let url = URL(string: ticket.downloadURL) else {
                throw StoreClient.ClientError.malformedResponse
            }

            let archive = try await Downloader.download(from: url) { [weak self] fraction in
                Task { @MainActor in self?.progress[app.id] = .downloading(fraction) }
            }
            defer { try? FileManager.default.removeItem(at: archive) }

            progress[app.id] = .verifying
            let result = try await Installer().install(
                archive: archive,
                expectedSHA256: ticket.sha256,
                replacing: installed[app.bundleID]
            )

            progress[app.id] = .installing
            installed = InstalledApps.scan()
            // 설치된 자리는 상세의 "설치된 위치" 가 말한다. 알림은 한눈에 읽히는 길이로 둔다.
            announce(result.replacedExisting
                ? before.replacedMessage(appName: app.name, version: version.shortVersion)
                : "\(Josa.object(app.name)) 설치했습니다.")
        } catch StoreClient.ClientError.unauthorized {
            signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
extension StoreModel {
    /// 서버 없이 목록 화면을 세운다. 미리보기와 화면 확인에만 쓴다.
    ///
    /// 로그인해야 목록이 뜨므로, 화면을 눈으로 보려면 서버와 계정이 있어야 했다. 이것은
    /// 그 자리를 건너뛰고 상태만 채운다. 릴리스 빌드에는 들어가지 않는다.
    func stage(
        meta: StoreMeta,
        user: UserDTO,
        apps: [AppDTO],
        installed: [String: InstalledApp] = [:],
        status: String? = nil
    ) {
        phase = .ready(meta, user)
        self.apps = apps
        self.installed = installed
        statusMessage = status
    }
}
#endif

