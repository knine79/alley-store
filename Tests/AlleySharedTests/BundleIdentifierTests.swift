import Testing

@testable import AlleyShared

@Suite("번들 ID 검증")
struct BundleIdentifierTests {
    @Test("정상적인 역방향 도메인 형식을 통과시킨다", arguments: [
        "com.example.app",
        "com.example.my-app",
        "io.example.tools.builder",
        "com.example2.app3",
    ])
    func acceptsWellFormedIdentifiers(_ bundleID: String) {
        #expect(BundleIdentifier.isWellFormed(bundleID))
    }

    @Test("형식에 어긋나는 값을 거부한다", arguments: [
        "",                    // 빈 값
        "singlesegment",       // 구간이 하나뿐
        "com..app",            // 빈 구간
        "com.example.",        // 끝이 점
        ".com.example",        // 시작이 점
        "com.example.my app",  // 공백
        "com.example.-app",    // 하이픈으로 시작
        "com.example.app-",    // 하이픈으로 끝
        "com.example.앱",       // 비ASCII
        "com.example.app_1",   // 언더스코어는 허용되지 않는다
    ])
    func rejectsMalformedIdentifiers(_ bundleID: String) {
        #expect(!BundleIdentifier.isWellFormed(bundleID))
    }

    @Test("프리픽스를 강제하지 않으면 형식만 본다")
    func skipsPrefixCheckWhenNotConfigured() throws {
        try BundleIdentifier.validate("org.other.app", requiredPrefix: nil)
        try BundleIdentifier.validate("org.other.app", requiredPrefix: "")
    }

    @Test("프리픽스가 맞으면 통과한다")
    func acceptsMatchingPrefix() throws {
        try BundleIdentifier.validate("com.example.tool", requiredPrefix: "com.example")
    }

    @Test("설정값에 끝점이 있어도 동일하게 취급한다")
    func normalizesTrailingDotInPrefix() throws {
        try BundleIdentifier.validate("com.example.tool", requiredPrefix: "com.example.")
    }

    @Test("프리픽스가 다르면 거부한다")
    func rejectsMismatchedPrefix() {
        #expect(throws: BundleIdentifier.ValidationError.prefixMismatch(expected: "com.example.")) {
            try BundleIdentifier.validate("org.other.tool", requiredPrefix: "com.example")
        }
    }

    @Test("프리픽스와 겹쳐 보이지만 경계가 다른 값을 거부한다")
    func rejectsPrefixLookalike() {
        // "com.example" 로 시작하지만 "com.example." 로는 시작하지 않는다.
        #expect(throws: BundleIdentifier.ValidationError.prefixMismatch(expected: "com.example.")) {
            try BundleIdentifier.validate("com.exampleevil.tool", requiredPrefix: "com.example")
        }
    }

    @Test("빈 번들 ID는 empty 에러를 낸다")
    func reportsEmptyIdentifier() {
        #expect(throws: BundleIdentifier.ValidationError.empty) {
            try BundleIdentifier.validate("   ", requiredPrefix: nil)
        }
    }
}
