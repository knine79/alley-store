import Foundation

/// 운영 파이프라인이 스토어 앱의 지금 상태를 물어볼 때 받는 것 (ADR-0046).
///
/// **CI 가 "이미 했나" 를 확인하는 데 쓴다.** 빌드 번호는 서버가 스스로 올리므로,
/// 같은 릴리스에 파이프라인이 두 번 돌면 버전이 하나 더 생긴다. 워커 릴리스는
/// 서버가 같은 버전을 거절해서 저절로 막히지만 여기는 그렇지 않다.
public struct StoreAppStatusDTO: Codable, Sendable, Equatable {
    public struct Build: Codable, Sendable, Equatable {
        public var shortVersion: String
        public var buildNumber: Int
        public var state: String

        public init(shortVersion: String, buildNumber: Int, state: String) {
            self.shortVersion = shortVersion
            self.buildNumber = buildNumber
            self.state = state
        }
    }

    public var bundleID: String
    public var appName: String
    /// 지금 올라가 있는 베이스 번들의 제품 버전. 없으면 nil.
    public var baseBundleVersion: String?
    /// 최근 빌드. 새것이 앞에 온다.
    public var builds: [Build]

    public init(
        bundleID: String,
        appName: String,
        baseBundleVersion: String? = nil,
        builds: [Build] = []
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.baseBundleVersion = baseBundleVersion
        self.builds = builds
    }
}
