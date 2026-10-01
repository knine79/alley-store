import AlleyShared
import Foundation
import Testing

@testable import AlleyStoreCore

/// 기본 브라우저로 로그인하고 커스텀 스킴으로 코드를 받는다 (ADR-0068).
///
/// 브라우저는 시험에서 띄울 수 없으므로 여는 동작을 바꿔 끼우고, 콜백은 `handle(url:)`
/// 을 직접 불러 넣는다. Apple Event 처리기가 하는 일이 그것뿐이다.
@MainActor
@Suite("브라우저 로그인")
struct WebSignInTests {
    static let server = URL(string: "https://store.example.com")!
    static let scheme = "alleystore"

    @Test("verifier 의 S256 이 RFC 7636 의 예와 같다")
    func challengeMatchesTheRFC() {
        // 서버(`PKCE.challenge`)도 같은 예로 시험한다. 둘이 어긋나면 아무도 로그인하지 못한다.
        #expect(
            WebSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("verifier 는 RFC 가 허용하는 문자로 43자다")
    func verifierShape() {
        let verifier = WebSignIn.makeVerifier()
        #expect(verifier.count == 43)
        #expect(verifier.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        })
        #expect(WebSignIn.makeVerifier() != verifier)
    }

    @Test("브라우저에 challenge 를 보내고, 돌아온 코드와 verifier 를 돌려준다")
    func roundTrip() async throws {
        let opener = Opener()
        let signIn = WebSignIn(open: opener.open)

        let started = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        let opened = try await opener.next()

        let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(opened.path == APIPath.googleAuthorize)
        #expect(items.first { $0.name == APIPath.clientQueryItem }?.value == APIPath.appClient)
        let challenge = try #require(items.first { $0.name == APIPath.codeChallengeQueryItem }?.value)
        let state = try #require(items.first { $0.name == APIPath.appStateQueryItem }?.value)

        #expect(signIn.handle(url: URL(string: "alleystore://auth?code=abc123&state=\(state)")!))
        let (code, verifier) = try await started.value
        #expect(code == "abc123")
        // 주소에 실린 것은 해시뿐이다. 원래 값은 교환할 때만 나간다.
        #expect(WebSignIn.challenge(for: verifier) == challenge)
        #expect(!opened.absoluteString.contains(verifier))
        #expect(!signIn.isWaiting)
    }

    @Test("다시 누르면 앞의 시도를 접는다")
    func aSecondAttemptCancelsTheFirst() async throws {
        let opener = Opener()
        let signIn = WebSignIn(open: opener.open)

        let first = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        _ = try await opener.next()
        let second = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        _ = try await opener.next()

        await #expect(throws: WebSignIn.SignInError.cancelled) { try await first.value }

        signIn.handle(url: URL(string: "alleystore://auth?code=second")!)
        #expect(try await second.value.code == "second")
    }

    /// 브라우저를 다시 켜면 복원된 예전 로그인 탭이 저절로 끝나 콜백을 보낸다.
    @Test("다른 로그인의 콜백은 버리고 계속 기다린다")
    func anotherAttemptsCallbackIsIgnored() async throws {
        let opener = Opener()
        let signIn = WebSignIn(open: opener.open)
        let started = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        let opened = try await opener.next()
        let state = try #require(
            URLComponents(url: opened, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == APIPath.appStateQueryItem }?.value
        )

        #expect(signIn.handle(url: URL(string: "alleystore://auth?code=stale&state=someone-else")!))
        #expect(signIn.isWaiting)

        signIn.handle(url: URL(string: "alleystore://auth?code=fresh&state=\(state)")!)
        #expect(try await started.value.code == "fresh")
    }

    /// 콜백에 값을 돌려주지 않는 예전 서버가 있다.
    @Test("값을 돌려주지 않는 콜백도 받는다")
    func aCallbackWithoutStateIsAccepted() async throws {
        let opener = Opener()
        let signIn = WebSignIn(open: opener.open)
        let started = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        _ = try await opener.next()

        signIn.handle(url: URL(string: "alleystore://auth?code=legacy")!)
        #expect(try await started.value.code == "legacy")
    }

    @Test("기다리지 않던 콜백은 버린다")
    func unsolicitedCallbacksAreDropped() {
        let signIn = WebSignIn(open: { _ in true })
        // 처리한 것으로 친다. 다른 데로 넘겨봐야 받을 곳이 없다.
        #expect(signIn.handle(url: URL(string: "alleystore://auth?code=stray")!))
        #expect(!signIn.isWaiting)
    }

    @Test("다른 스킴이나 다른 호스트는 로그인 콜백이 아니다")
    func otherURLsAreNotCallbacks() async throws {
        let opener = Opener()
        let signIn = WebSignIn(open: opener.open)
        let started = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        _ = try await opener.next()

        #expect(!signIn.handle(url: URL(string: "alleystore://somewhere?code=x")!))
        signIn.handle(url: URL(string: "otherscheme://auth?code=x")!)
        #expect(signIn.isWaiting)

        signIn.cancel()
        await #expect(throws: WebSignIn.SignInError.cancelled) { try await started.value }
    }

    @Test("코드 없이 돌아오면 그렇게 알린다")
    func aCallbackWithoutACode() async throws {
        let opener = Opener()
        let signIn = WebSignIn(open: opener.open)
        let started = Task { try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme) }
        _ = try await opener.next()

        signIn.handle(url: URL(string: "alleystore://auth")!)
        await #expect(throws: WebSignIn.SignInError.noCode) { try await started.value }
    }

    @Test("브라우저를 열지 못하면 기다리지 않는다")
    func failingToOpenTheBrowser() async {
        let signIn = WebSignIn(open: { _ in false })
        await #expect(throws: WebSignIn.SignInError.failed("브라우저를 열지 못했습니다.")) {
            try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme)
        }
        #expect(!signIn.isWaiting)
    }

    @Test("끝없이 기다리지 않는다")
    func itGivesUpEventually() async {
        let signIn = WebSignIn(open: { _ in true }, timeout: .milliseconds(50))
        await #expect(throws: WebSignIn.SignInError.timedOut) {
            try await signIn.authorize(server: Self.server, callbackScheme: Self.scheme)
        }
        #expect(!signIn.isWaiting)
    }
}

/// 브라우저 대신 연 주소를 받아두는 자리.
@MainActor
private final class Opener {
    private var opened: [URL] = []
    private var waiter: CheckedContinuation<URL, Never>?

    func open(_ url: URL) -> Bool {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: url)
        } else {
            opened.append(url)
        }
        return true
    }

    func next() async throws -> URL {
        if !opened.isEmpty { return opened.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}
