import AlleyShared
import Foundation
import Vapor

/// 스토리지에 있는 작은 이미지를 프로세스 안에 잠깐 들고 있는다.
///
/// 세 자리가 쓴다. 브랜딩 이미지(ADR-0045), 앱 아이콘, 그리고 스토어 앱을 빌드할
/// 때 번들에 넣을 아이콘이다. 처음에는 브랜딩 전용이었는데 앱 아이콘이 같은 것을
/// 필요로 해서 여기로 올렸다. 이름이 쓰임을 따라간다.
///
/// 파비콘은 화면을 그릴 때마다, 앱 아이콘은 목록의 줄마다 요청된다. 그때마다
/// 스토리지를 다녀오면 페이지 하나에 왕복이 여럿 붙는다.
///
/// **무효화를 걱정하지 않아도 된다.** 키에 UUID 가 들어 있어서 그림이 바뀌면 키가
/// 통째로 바뀐다. 옛 키로 들고 있던 내용은 아무도 다시 묻지 않는다. 그래서 서버가
/// 여러 대여도 한 대의 캐시가 다른 대의 변경을 가리는 일이 없다.
actor StoredImageCache {
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
    private struct StoredImageCacheKey: StorageKey {
        typealias Value = StoredImageCache
    }

    var storedImages: StoredImageCache {
        if let existing = storage[StoredImageCacheKey.self] { return existing }
        let cache = StoredImageCache()
        storage[StoredImageCacheKey.self] = cache
        return cache
    }
}
