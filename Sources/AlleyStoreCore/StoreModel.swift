import AlleyShared
import Foundation
import Observation

/// 앱 전체가 보는 상태.
///
/// 화면은 이 하나만 읽는다. 서버 주소를 넣기 전, 로그인 전, 목록을 보는 중이 모두
/// 같은 창에서 이어지므로 상태를 나눠 들고 있으면 어느 것이 진짜인지 흐려진다.
@MainActor
@Observable
final class StoreModel {
    /// 지금 앱이 서 있는 자리.
    enum Phase: Equatable {
        /// 서버 주소를 아직 모른다. 첫 실행이다.
        case needsServer
        /// 서버는 알지만 로그인하지 않았다.
        case signedOut(StoreMeta)
        case ready(StoreMeta, UserDTO)
    }

    /// 앱 하나를 설치하는 동안의 진행 상황.
    enum Progress: Equatable {
        case downloading(Double)
        case verifying
        case installing
    }

    private(set) var phase: Phase = .needsServer
    private(set) var apps: [AppDTO] = []
    private(set) var installed: [String: InstalledApp] = [:]
    private(set) var isLoading = false
    /// 앱별 진행 상황. 목록에서 여러 개를 동시에 받을 수 있다.
    private(set) var progress: [UUID: Progress] = [:]

    var errorMessage: String?
    /// 방금 무엇을 했는지 알리는 한 줄. 설치가 끝났다는 것 정도.
    var statusMessage: String?

    private let credentials = Credentials()
    private var client: StoreClient?

    // MARK: - 시작

    /// 저장된 서버와 토큰으로 되돌아간다.
    func restore() async {
        guard let server = credentials.serverURL else { return }
        await connect(to: server, remember: false)
    }

    /// 서버 주소를 확인하고 붙는다.
    ///
    /// `/meta` 가 돌아오면 Alley 서버가 맞다. 이름과 색과 허용 도메인을 여기서 받는다.
    func connect(to server: URL, remember: Bool = true) async {
        isLoading = true
        defer { isLoading = false }

        var probe = StoreClient(server: server)
        do {
            let meta = try await probe.meta()
            if remember {
                credentials.serverURL = server
            }
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

    /// 저장된 서버 주소를 지우고 처음으로 돌아간다.
    func forgetServer() {
        if let server = credentials.serverURL {
            credentials.setToken(nil, for: server)
        }
        credentials.serverURL = nil
        client = nil
        apps = []
        phase = .needsServer
    }

    // MARK: - 로그인

    func signIn() async {
        guard let client, case .signedOut(let meta) = phase else { return }

        do {
            let code = try await WebSignIn().authorize(
                server: client.server,
                callbackScheme: meta.callbackURLScheme
            )
            let exchanged = try await client.exchange(code: code)
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
            apps = try await remote.sorted { $0.name < $1.name }
            installed = scanned
        } catch StoreClient.ClientError.unauthorized {
            signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func state(of app: AppDTO) -> InstallState {
        InstallState.compare(
            installed: installed[app.bundleID],
            releasedBuild: app.latestReleasedVersion?.buildNumber
        )
    }

    // MARK: - 설치

    /// 최신 출시본을 받아 설치한다.
    func install(_ app: AppDTO) async {
        guard let client, let version = app.latestReleasedVersion else { return }
        guard progress[app.id] == nil else { return }

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
            statusMessage = result.replacedExisting
                ? "\(app.name) 을(를) \(version.shortVersion) 로 업데이트했습니다."
                : "\(app.name) 을(를) \(result.location.path) 에 설치했습니다."
        } catch StoreClient.ClientError.unauthorized {
            signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
