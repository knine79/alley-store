import AlleyShared
import Fluent
import Foundation
import Vapor

/// 브랜딩 이미지를 내주는 자리.
///
/// **로그인을 걸지 않는다.** 파비콘은 로그인 화면의 탭에 뜨고, 앱 아이콘은 스토어
/// 앱이 아직 로그인하기 전에 받아간다. 관리자가 "이걸 우리 얼굴로 쓰겠다" 고 올린
/// 그림이라 감출 것도 없다.
struct BrandingController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("branding", ":asset", use: serve)
    }

    @Sendable
    func serve(request: Request) async throws -> Response {
        guard let name = request.parameters.get("asset"),
              let kind = Self.kind(forFileName: name)
        else {
            throw Abort(.notFound)
        }
        guard let asset = try await BrandingAssetService.find(kind: kind, on: request.db) else {
            // 안 올린 것과 없는 주소는 다르지만, 브라우저에게는 둘 다 "그림이 없다" 다.
            throw Abort(.notFound)
        }

        // 키에 UUID 가 들어 있어 내용이 바뀌면 키도 바뀐다. 그래서 키 자체가
        // 그대로 ETag 가 된다. 따로 해시를 뜨지 않아도 된다.
        let etag = "\"\(asset.storageKey)\""
        if request.headers.first(name: .ifNoneMatch) == etag {
            let response = Response(status: .notModified)
            Self.applyCacheHeaders(to: response, etag: etag)
            return response
        }

        let data = try await request.application.brandingCache.data(forKey: asset.storageKey) {
            try await request.application.artifactStorage.get(
                key: asset.storageKey,
                limit: BrandingAssetService.maximumUploadSize
            )
        }

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "image", subType: "png")
        Self.applyCacheHeaders(to: response, etag: etag)
        response.body = .init(data: data)
        return response
    }

    /// `favicon.png` 같은 파일 이름을 종류로 바꾼다.
    ///
    /// 경로에 확장자를 두는 이유는 브라우저가 파비콘을 다룰 때 그것을 보기 때문이다.
    /// 확장자 없는 주소를 파비콘으로 주면 무시하는 브라우저가 있다.
    static func kind(forFileName name: String) -> BrandingAssetKind? {
        guard name.hasSuffix(".png") else { return nil }
        return BrandingAssetKind(rawValue: String(name.dropLast(4)))
    }

    /// 60초만 들고 있게 한다.
    ///
    /// 화면의 링크에는 `?v=` 가 붙어 있어서 바꾼 그림은 바로 보인다. 이 값은 그
    /// 표시가 없는 주소 - 스토어 앱이 받아가는 앱 아이콘, 브라우저가 스스로 찾는
    /// `/favicon.ico` 대체 - 를 위한 것이다. 길게 잡으면 로고를 바꿨는데 하루 동안
    /// 옛것이 보이고, 짧게 잡아도 ETag 덕에 오가는 것은 헤더뿐이다.
    private static func applyCacheHeaders(to response: Response, etag: String) {
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=60")
    }
}

// MARK: - 캐시

/// 브랜딩 이미지를 프로세스 안에 잠깐 들고 있는다.
///
/// 파비콘은 화면을 그릴 때마다 요청된다. 그때마다 스토리지를 다녀오면 페이지 하나에
/// 왕복이 하나 더 붙는다.
///
/// **무효화를 걱정하지 않아도 된다.** 키에 UUID 가 들어 있어서 그림이 바뀌면 키가
/// 통째로 바뀐다. 옛 키로 들고 있던 내용은 아무도 다시 묻지 않는다. 그래서 서버가
/// 여러 대여도 한 대의 캐시가 다른 대의 변경을 가리는 일이 없다.
actor BrandingAssetCache {
    /// 들고 있을 총량. 이미지 몇 장이면 충분하다.
    private let maximumBytes = 32 * 1024 * 1024

    private var entries: [String: Data] = [:]
    /// 넣은 순서. 넘치면 오래된 것부터 버린다.
    private var insertionOrder: [String] = []
    private var totalBytes = 0

    func data(forKey key: String, load: () async throws -> Data) async throws -> Data {
        if let cached = entries[key] { return cached }

        let data = try await load()
        // 한 장이 상한을 통째로 먹으면 캐시가 캐시 노릇을 못 한다. 그런 것은 그냥
        // 내주기만 하고 들고 있지 않는다.
        guard data.count <= maximumBytes / 2 else { return data }

        entries[key] = data
        insertionOrder.append(key)
        totalBytes += data.count

        while totalBytes > maximumBytes, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            totalBytes -= entries.removeValue(forKey: oldest)?.count ?? 0
        }
        return data
    }
}

extension Application {
    private struct BrandingCacheKey: StorageKey {
        typealias Value = BrandingAssetCache
    }

    var brandingCache: BrandingAssetCache {
        if let existing = storage[BrandingCacheKey.self] { return existing }
        let cache = BrandingAssetCache()
        storage[BrandingCacheKey.self] = cache
        return cache
    }
}
