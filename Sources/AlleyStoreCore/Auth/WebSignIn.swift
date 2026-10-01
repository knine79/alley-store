import AlleyShared
import AppKit
import CryptoKit
import Foundation
import os

/// 기본 브라우저에서 로그인하고 일회용 코드를 받아온다 (ADR-0068).
///
/// **`ASWebAuthenticationSession` 을 쓰지 않는다.** macOS 는 기본 브라우저가 지원하면
/// 그 브라우저에 로그인을 맡기는데, 그 구간은 앱이 들여다볼 수도 손댈 수도 없다.
/// Chrome 이 끝나지 않은 요청을 쥐고 있으면 버튼을 눌러도 포커스만 넘어가고 멈췄고,
/// 앱을 다시 띄워도 풀리지 않았다. 브라우저를 껐다 켜야 풀렸다.
///
/// 대신 로그인 주소를 기본 브라우저로 그냥 열고, 서버가 돌려보내는 커스텀 스킴 URL 을
/// 앱이 Apple Event 로 받는다. 커스텀 스킴은 어느 브라우저든 LaunchServices 로 넘기므로
/// 브라우저마다 다른 구현에 기대지 않는다.
///
/// 그 URL 은 같은 스킴을 등록한 다른 앱도 받을 수 있다. 그래서 **PKCE 를 붙인다.**
/// 로그인을 시작할 때 verifier 의 해시만 보내고, 코드를 교환할 때 verifier 를 보낸다.
/// 코드를 가로챈 앱에는 verifier 가 없다. 세션 토큰 대신 코드를 받는 이유(ADR-0008)는
/// 그대로다.
@MainActor
final class WebSignIn {
    enum SignInError: LocalizedError, Equatable {
        case cancelled
        case noCode
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil  // 사용자가 다시 눌렀거나 그만둔 것뿐이다. 오류로 띄우지 않는다.
            case .noCode: return "로그인은 됐지만 인증 코드를 받지 못했습니다. 다시 시도해주세요."
            case .timedOut: return "브라우저에서 로그인이 끝나지 않았습니다. 다시 시도해주세요."
            case .failed(let detail): return "로그인에 실패했습니다.\n\(detail)"
            }
        }
    }

    /// 앱 하나에 하나다. Apple Event 처리기가 기다리는 로그인을 찾아갈 자리가 필요하다.
    static let shared = WebSignIn()

    /// 서버가 state 를 10분만 받는다(`OAuthStateToken.lifetime`). 그 뒤에 돌아오는
    /// 콜백은 없으므로 더 기다리지 않는다.
    static let defaultTimeout: Duration = .seconds(10 * 60)

    /// subsystem 은 번들 ID 다 (`Credentials` 와 같은 이유). 사용자 맥에서 로그를 받을 때
    /// `log stream --predicate 'category == "sign-in"'` 으로 이것만 걸러낸다.
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "alley-store",
        category: "sign-in"
    )

    private struct Pending {
        let scheme: String
        let continuation: CheckedContinuation<String, any Error>
        let timeout: Task<Void, Never>
    }

    private var pending: Pending?
    private let open: @MainActor (URL) -> Bool
    private let timeout: Duration

    init(
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        timeout: Duration = WebSignIn.defaultTimeout
    ) {
        self.open = open
        self.timeout = timeout
    }

    /// 지금 브라우저에서 로그인이 끝나기를 기다리는 중인지.
    var isWaiting: Bool { pending != nil }

    /// 브라우저를 열고 코드를 받는다. 교환할 때 쓸 verifier 를 함께 돌려준다.
    ///
    /// **이미 기다리는 로그인이 있으면 그것을 접는다.** 사람이 버튼을 다시 누른 것은
    /// 앞의 시도를 버리겠다는 뜻이다. 접지 않으면 앞의 것이 끝까지 남아 다음 콜백을
    /// 엉뚱한 쪽이 받는다.
    func authorize(server: URL, callbackScheme: String) async throws -> (code: String, verifier: String) {
        finish(with: .failure(SignInError.cancelled))

        let verifier = Self.makeVerifier()
        var components = URLComponents(
            url: server.appendingPathComponent(APIPath.googleAuthorize),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            // 이 항목이 있어야 서버가 웹이 아니라 앱으로 돌려보낸다.
            URLQueryItem(name: APIPath.clientQueryItem, value: APIPath.appClient),
            URLQueryItem(name: APIPath.codeChallengeQueryItem, value: Self.challenge(for: verifier)),
        ]
        guard let url = components?.url else {
            throw SignInError.failed("서버 주소가 올바르지 않습니다.")
        }

        let code: String = try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                Self.log.notice("브라우저 로그인을 기다리다 시간이 다 됐습니다")
                self?.finish(with: .failure(SignInError.timedOut))
            }
            pending = Pending(scheme: callbackScheme, continuation: continuation, timeout: timeout)

            Self.log.notice("브라우저로 로그인을 엽니다 [콜백 스킴: \(callbackScheme, privacy: .public)]")
            guard open(url) else {
                finish(with: .failure(SignInError.failed("브라우저를 열지 못했습니다.")))
                return
            }
        }
        return (code, verifier)
    }

    /// 들어온 URL 이 로그인 콜백이면 처리하고 true 를 돌려준다.
    ///
    /// 기다리는 로그인이 없을 때 온 콜백은 버린다. 누가 보냈는지 모르는 코드를 교환하면
    /// 남의 계정으로 로그인될 수 있다. PKCE 가 그것도 막지만, 기다리지 않던 것을 받을
    /// 이유가 없다.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "auth"
        else { return false }

        guard let pending, components.scheme?.lowercased() == pending.scheme.lowercased() else {
            Self.log.notice("기다리지 않던 로그인 콜백을 버립니다")
            return true
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            Self.log.error("로그인 콜백에 코드가 없습니다")
            finish(with: .failure(SignInError.noCode))
            return true
        }
        // 코드 값은 남기지 않는다. 2분이지만 자격증명이다.
        Self.log.notice("로그인 콜백을 받았습니다")
        finish(with: .success(code))
        // 사람은 브라우저에 있다. 끝났으면 앱을 앞으로 가져와야 끝난 줄 안다.
        NSApplication.shared.activate()
        return true
    }

    /// 기다리던 로그인을 끝낸다. 없으면 아무것도 하지 않는다.
    func cancel() {
        finish(with: .failure(SignInError.cancelled))
    }

    private func finish(with result: Result<String, any Error>) {
        guard let pending else { return }
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    // MARK: - PKCE

    /// 32바이트 무작위 값을 base64url 로 적는다. 43자가 된다 (RFC 7636 이 권하는 길이).
    nonisolated static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "난수를 만들지 못했습니다")
        return base64URL(Data(bytes))
    }

    /// verifier 의 SHA-256 을 base64url 로 적는다. 서버의 `PKCE.challenge` 와 같아야 한다.
    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
