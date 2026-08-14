import Testing

@testable import AlleyServer

@Suite("로그인 도메인 정책")
struct EmailDomainPolicyTests {
    let policy = EmailDomainPolicy(allowedDomains: ["example.com", "example.org"])

    @Test("허용 도메인 계정을 통과시킨다")
    func admitsAllowedDomain() throws {
        let email = try policy.admit(
            email: "alice@example.com",
            emailVerified: true,
            hostedDomain: "example.com"
        )
        #expect(email == "alice@example.com")
    }

    @Test("허용 도메인이 여러 개면 각각 통과한다")
    func admitsEachAllowedDomain() throws {
        try policy.admit(email: "a@example.com", emailVerified: true, hostedDomain: nil)
        try policy.admit(email: "b@example.org", emailVerified: true, hostedDomain: nil)
    }

    @Test("허용 목록 밖 도메인을 거부한다")
    func rejectsOtherDomain() {
        #expect(throws: EmailDomainPolicy.Rejection.domainNotAllowed(domain: "other.example")) {
            try policy.admit(email: "someone@other.example", emailVerified: true, hostedDomain: nil)
        }
    }

    @Test("도메인 접미사가 겹치는 값을 거부한다")
    func rejectsSuffixLookalike() {
        // "evil-store.test" 는 "store.test" 로 끝나지만 다른 도메인이다.
        // 접미사 비교로 구현하면 통과해버린다.
        let strict = EmailDomainPolicy(allowedDomains: ["store.test"])
        #expect(throws: EmailDomainPolicy.Rejection.domainNotAllowed(domain: "evil-store.test")) {
            try strict.admit(email: "evil@evil-store.test", emailVerified: true, hostedDomain: nil)
        }
    }

    @Test("하위 도메인을 자동으로 허용하지 않는다")
    func rejectsSubdomain() {
        #expect(throws: EmailDomainPolicy.Rejection.domainNotAllowed(domain: "sub.example.com")) {
            try policy.admit(email: "a@sub.example.com", emailVerified: true, hostedDomain: nil)
        }
    }

    @Test("미인증 이메일을 거부한다")
    func rejectsUnverifiedEmail() {
        #expect(throws: EmailDomainPolicy.Rejection.emailNotVerified) {
            try policy.admit(email: "alice@example.com", emailVerified: false, hostedDomain: nil)
        }
    }

    @Test("email_verified 가 없으면 거부한다")
    func rejectsMissingVerificationClaim() {
        // claim 이 빠졌다고 통과시키면 미인증 계정이 들어온다.
        #expect(throws: EmailDomainPolicy.Rejection.emailNotVerified) {
            try policy.admit(email: "alice@example.com", emailVerified: nil, hostedDomain: nil)
        }
    }

    @Test("이메일이 없으면 거부한다")
    func rejectsMissingEmail() {
        #expect(throws: EmailDomainPolicy.Rejection.emailMissing) {
            try policy.admit(email: nil, emailVerified: true, hostedDomain: nil)
        }
    }

    @Test("형식이 깨진 이메일을 거부한다", arguments: [
        "noatsign", "@example.com", "alice@", "a@b@example.com",
    ])
    func rejectsMalformedEmail(_ value: String) {
        #expect(throws: EmailDomainPolicy.Rejection.self) {
            try policy.admit(email: value, emailVerified: true, hostedDomain: nil)
        }
    }

    @Test("이메일 도메인과 hd 가 다르면 거부한다")
    func rejectsHostedDomainMismatch() {
        #expect(throws: EmailDomainPolicy.Rejection.hostedDomainMismatch(
            email: "alice@example.com",
            hostedDomain: "example.org"
        )) {
            try policy.admit(
                email: "alice@example.com",
                emailVerified: true,
                hostedDomain: "example.org"
            )
        }
    }

    @Test("hd 가 없는 계정도 도메인이 맞으면 통과한다")
    func admitsWithoutHostedDomainClaim() throws {
        // 개인 Google 계정에는 hd 가 없다. 도메인 검증은 이메일로 한다.
        try policy.admit(email: "alice@example.com", emailVerified: true, hostedDomain: nil)
    }

    @Test("대소문자를 구분하지 않고 소문자로 정규화한다")
    func normalizesCase() throws {
        let email = try policy.admit(
            email: "Alice@Example.COM",
            emailVerified: true,
            hostedDomain: "Example.com"
        )
        #expect(email == "alice@example.com")
    }

    @Test("설정값의 대소문자와 공백도 정규화한다")
    func normalizesConfiguredDomains() throws {
        let loose = EmailDomainPolicy(allowedDomains: [" Example.COM ", "", "  "])
        #expect(loose.allowedDomains == ["example.com"])
        try loose.admit(email: "a@example.com", emailVerified: true, hostedDomain: nil)
    }

    @Test("허용 목록이 비어 있으면 도메인을 제한하지 않는다")
    func allowsAnyDomainWhenUnconfigured() throws {
        let open = EmailDomainPolicy(allowedDomains: [])
        try open.admit(email: "anyone@anywhere.example", emailVerified: true, hostedDomain: nil)
    }

    @Test("목록이 비어 있어도 미인증 계정은 거부한다")
    func stillRejectsUnverifiedWhenUnconfigured() {
        let open = EmailDomainPolicy(allowedDomains: [])
        #expect(throws: EmailDomainPolicy.Rejection.emailNotVerified) {
            try open.admit(email: "anyone@anywhere.example", emailVerified: false, hostedDomain: nil)
        }
    }
}
