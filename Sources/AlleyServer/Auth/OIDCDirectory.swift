import Foundation
import JWTKit
import Vapor

/// 공급자의 설정 문서와 공개키를 받아 잠깐 들고 있는다 (ADR-0047).
///
/// **로그인마다 두 번 나가면 안 된다.** discovery 문서와 JWKS 는 로그인 한 번에
/// 한 번씩 필요한데, 둘 다 몇 시간 단위로 바뀌지 않는 값이다.
///
/// 그렇다고 영원히 들고 있을 수도 없다. **공급자는 서명 키를 주기적으로 바꾼다.**
/// Google 은 며칠에 한 번, 다른 곳도 비슷하다. 낡은 키만 들고 있으면 어느 날 갑자기
/// 아무도 로그인하지 못한다.
///
/// 그래서 두 가지를 한다.
///
/// - 수명을 두고 그 뒤에는 다시 받는다
/// - **모르는 키로 서명된 토큰을 만나면 수명과 무관하게 즉시 다시 받는다.** 키 교체
///   직후가 그 순간이고, 그때 기다리게 하면 그 시간 동안 로그인이 막힌다
actor OIDCDirectory {
    /// 설정 문서를 다시 받기까지.
    ///
    /// 엔드포인트 주소는 키보다 훨씬 덜 바뀐다. 길게 잡아도 된다.
    static let metadataLifetime: TimeInterval = 60 * 60 * 12

    /// 공개키를 다시 받기까지.
    ///
    /// 짧게 잡는다고 안전해지지는 않는다. 진짜 방어는 아래의 "모르는 키면 바로
    /// 다시 받는다" 쪽이고, 이 값은 그 경로가 없을 때의 뒷받침이다.
    static let keysLifetime: TimeInterval = 60 * 60

    private struct Cached<Value: Sendable>: Sendable {
        var value: Value
        var fetchedAt: Date

        func isFresh(for lifetime: TimeInterval, now: Date) -> Bool {
            now.timeIntervalSince(fetchedAt) < lifetime
        }
    }

    private var metadata: Cached<OIDCMetadata>?
    private var keys: Cached<JWTKeyCollection>?
    /// 지금 캐시에 든 키들의 `kid`. 모르는 키를 알아보는 데 쓴다.
    private var knownKeyIDs: Set<String> = []

    private let issuer: String
    private let now: @Sendable () -> Date

    init(issuer: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.issuer = issuer
        self.now = now
    }

    // MARK: - 설정 문서

    func metadata(using client: any Client, logger: Logger) async throws -> OIDCMetadata {
        if let cached = metadata, cached.isFresh(for: Self.metadataLifetime, now: now()) {
            return cached.value
        }

        let url = OIDCMetadata.discoveryURL(issuer: issuer)
        let response = try await client.get(URI(string: url))
        guard response.status == .ok else {
            // 낡았어도 있으면 그것을 쓴다. 공급자가 잠깐 흔들린다고 로그인을 통째로
            // 막을 이유가 없다. 엔드포인트 주소는 거의 바뀌지 않는다.
            if let stale = metadata?.value {
                logger.warning("로그인 공급자 설정을 갱신하지 못해 이전 값을 씁니다 [\(response.status.code)]")
                return stale
            }
            throw OIDCError.discoveryFailed(issuer: issuer, status: response.status)
        }

        let document = try response.content.decode(OIDCMetadata.self).validated(against: issuer)
        metadata = Cached(value: document, fetchedAt: now())
        logger.notice("로그인 공급자 설정을 읽었습니다 [\(document.issuer)]")
        return document
    }

    // MARK: - 공개키

    /// ID 토큰의 서명을 검증한다.
    ///
    /// - Parameter keyID: 토큰 헤더의 `kid`. 캐시에 없는 값이면 키를 다시 받는다.
    func verify(
        idToken: String,
        keyID: String?,
        using client: any Client,
        logger: Logger
    ) async throws -> OIDCIdentityToken {
        let document = try await metadata(using: client, logger: logger)

        let needsRefresh: Bool
        if let cached = keys, cached.isFresh(for: Self.keysLifetime, now: now()) {
            // 수명이 남았어도 모르는 키면 다시 받는다. 공급자가 방금 키를 바꾼
            // 경우이고, 여기서 기다리면 그동안 아무도 못 들어온다.
            needsRefresh = keyID.map { !knownKeyIDs.contains($0) } ?? false
            if needsRefresh {
                logger.notice("모르는 서명 키를 만나 공개키를 다시 받습니다 [kid: \(keyID ?? "-")]")
            }
        } else {
            needsRefresh = true
        }

        if needsRefresh {
            try await refreshKeys(from: document, using: client, logger: logger)
        }
        guard let collection = keys?.value else {
            throw OIDCError.discoveryFailed(issuer: issuer, status: .serviceUnavailable)
        }
        return try await collection.verify(idToken, as: OIDCIdentityToken.self)
    }

    private func refreshKeys(
        from document: OIDCMetadata,
        using client: any Client,
        logger: Logger
    ) async throws {
        let response = try await client.get(URI(string: document.jwksURI))
        guard response.status == .ok, let buffer = response.body else {
            if keys != nil {
                logger.warning("공개키를 갱신하지 못해 이전 값을 씁니다 [\(response.status.code)]")
                return
            }
            throw OIDCError.discoveryFailed(issuer: issuer, status: response.status)
        }

        let jwks = try JSONDecoder().decode(JWKS.self, from: Data(buffer: buffer))
        let collection = JWTKeyCollection()
        try await collection.add(jwks: jwks)

        keys = Cached(value: collection, fetchedAt: now())
        knownKeyIDs = Set(jwks.keys.compactMap { $0.keyIdentifier?.string })
        logger.notice("로그인 공급자 공개키를 읽었습니다 [\(knownKeyIDs.count)개]")
    }
}

// MARK: - 앱에 붙이기

extension Application {
    private struct OIDCDirectoryKey: StorageKey {
        typealias Value = OIDCDirectory
    }

    /// 이 스토어가 쓰는 공급자의 설정·공개키 보관소.
    var oidcDirectory: OIDCDirectory {
        if let existing = storage[OIDCDirectoryKey.self] { return existing }
        let directory = OIDCDirectory(issuer: alleyConfig.oauth.issuer)
        storage[OIDCDirectoryKey.self] = directory
        return directory
    }
}

// MARK: - 토큰 머리 읽기

/// 서명을 검증하기 **전에** 헤더의 `kid` 만 꺼낸다.
///
/// 이 값으로 "캐시에 없는 키인가" 를 판단한다. 검증 전에 읽는 값이라 **믿고 쓰지
/// 않는다.** 여기서 하는 일은 공개키를 다시 받을지 정하는 것뿐이고, 거짓이면 다시
/// 받아본 뒤 검증에서 걸린다.
enum JWTHeaderPeek {
    static func keyID(of token: String) -> String? {
        let parts = token.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[0])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let header = try? JSONDecoder().decode(Header.self, from: data)
        else { return nil }
        return header.kid
    }

    private struct Header: Decodable {
        var kid: String?
    }
}
