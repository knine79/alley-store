import AlleyShared
import AuthenticationServices
import Foundation

/// 브라우저를 띄워 로그인하고 일회용 코드를 받아온다.
///
/// `ASWebAuthenticationSession` 을 쓰는 이유는 두 가지다. 사용자의 비밀번호가 이 앱을
/// 지나지 않고, Google 이 앱 안에 박힌 웹뷰로 하는 로그인을 막기 때문이다.
///
/// 서버는 인증이 끝나면 커스텀 스킴으로 돌려보낸다. 세션 토큰이 아니라 코드를 주고,
/// 그 코드를 앱이 한 번 더 교환한다(ADR-0008). 리다이렉트 URL 은 다른 앱도 가로챌 수
/// 있어서 거기에 토큰을 실을 수 없다.
@MainActor
final class WebSignIn: NSObject {
    enum SignInError: LocalizedError {
        case cancelled
        case noCode
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil  // 사용자가 창을 닫은 것뿐이다. 오류로 띄우지 않는다.
            case .noCode: return "로그인은 됐지만 인증 코드를 받지 못했습니다. 다시 시도해주세요."
            case .failed(let detail): return "로그인에 실패했습니다.\n\(detail)"
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    /// 로그인 창을 띄우고 코드를 받는다.
    func authorize(server: URL, callbackScheme: String) async throws -> String {
        var components = URLComponents(
            url: server.appendingPathComponent(APIPath.googleAuthorize),
            resolvingAgainstBaseURL: false
        )
        // 이 항목이 있어야 서버가 웹이 아니라 앱으로 돌려보낸다.
        components?.queryItems = [
            URLQueryItem(name: APIPath.clientQueryItem, value: APIPath.appClient)
        ]
        guard let url = components?.url else {
            throw SignInError.failed("서버 주소가 올바르지 않습니다.")
        }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code
                        == .canceledLogin
                    continuation.resume(
                        throwing: cancelled
                            ? SignInError.cancelled
                            : SignInError.failed(error.localizedDescription)
                    )
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: SignInError.noCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            // 사파리에 남은 세션을 그대로 쓴다. 조직 계정으로 이미 로그인해 있으면
            // 계정을 다시 고르지 않아도 된다.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
        else {
            throw SignInError.noCode
        }
        return code
    }
}

extension WebSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}
