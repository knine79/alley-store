import Foundation
import Testing
import Vapor

@testable import AlleyServer

/// 최소한의 PNG 머리를 만든다.
///
/// 픽셀은 넣지 않는다. 검사가 읽는 것은 앞 24바이트뿐이라(`PNGInspection`) 그만큼만
/// 있으면 된다. CRC 도 맞추지 않는다. 검사가 보지 않고, 맞춰봐야 이 시험이 무엇을
/// 확인하는지만 흐려진다.
enum PNGFixture {
    static func png(width: Int, height: Int) -> Data {
        var data = Data(PNGInspection.signature)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])  // IHDR 길이 13
        data.append(contentsOf: Array("IHDR".utf8))
        data.append(contentsOf: bigEndian(width))
        data.append(contentsOf: bigEndian(height))
        data.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00])  // 8비트 RGBA
        return data
    }

    private static func bigEndian(_ value: Int) -> [UInt8] {
        let v = UInt32(value)
        return [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}

@Suite("브랜딩 이미지 검사")
struct PNGInspectionTests {
    @Test("머리에서 크기를 읽는다")
    func readsSize() throws {
        let size = try PNGInspection.size(of: PNGFixture.png(width: 1024, height: 512))
        #expect(size.width == 1024)
        #expect(size.height == 512)
    }

    /// 확장자만 바꾼 파일을 올리는 일이 흔하다. 그 상태로 `.icns` 에 담으면 아이콘
    /// 자리가 비어 나오고, 그 사실은 앱을 Dock 에 띄운 뒤에야 드러난다.
    @Test("PNG 가 아니면 거절한다")
    func rejectsNonPNG() {
        // JPEG 의 시작 바이트. 이름만 .png 로 바꾼 파일이 이렇게 생겼다.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpeg.append(Data(count: 40))

        #expect(throws: (any Error).self) {
            try PNGInspection.size(of: jpeg)
        }
    }

    @Test("머리가 잘린 파일을 거절한다")
    func rejectsTruncated() {
        #expect(throws: (any Error).self) {
            try PNGInspection.size(of: Data(PNGInspection.signature))
        }
    }

    /// 실패 문구에 받은 크기가 들어가야 한다. "정사각형이 아닙니다" 만으로는
    /// 무엇을 고쳐야 하는지 모른다.
    @Test("정사각형이 아니면 받은 크기를 말해준다")
    func rejectsNonSquareWithSize() {
        do {
            _ = try PNGInspection.validate(
                PNGFixture.png(width: 1024, height: 512), rule: .atLeast(512), label: "앱 아이콘"
            )
            Issue.record("거절했어야 합니다.")
        } catch let abort as any AbortError {
            #expect(abort.reason.contains("1024×512"))
            #expect(abort.reason.contains("앱 아이콘"))
        } catch {
            Issue.record("AbortError 가 아닙니다: \(error)")
        }
    }

    @Test("최소 크기보다 작으면 거절한다")
    func rejectsTooSmall() {
        #expect(throws: (any Error).self) {
            try PNGInspection.validate(
                PNGFixture.png(width: 256, height: 256), rule: .atLeast(512), label: "앱 아이콘"
            )
        }
    }

    @Test("조건을 만족하면 통과한다")
    func acceptsSquareAndLargeEnough() throws {
        let size = try PNGInspection.validate(
            PNGFixture.png(width: 1024, height: 1024), rule: .atLeast(512), label: "앱 아이콘"
        )
        #expect(size.isSquare)
    }
}

@Suite("브랜딩 이미지 주소")
struct BrandingAssetPathTests {
    @Test("종류마다 공개 경로가 다르다")
    func publicPaths() {
        #expect(BrandingAssetKind.favicon.publicPath == "/branding/favicon.png")
        #expect(BrandingAssetKind.appIcon.publicPath == "/branding/app-icon.png")
    }

    /// 파비콘 주소에 확장자를 두는 이유가 여기 있다. 확장자로 종류를 찾는다.
    @Test("파일 이름에서 종류를 찾는다")
    func kindFromFileName() {
        #expect(BrandingController.kind(forFileName: "favicon.png") == .favicon)
        #expect(BrandingController.kind(forFileName: "app-icon.png") == .appIcon)
        #expect(BrandingController.kind(forFileName: "logo.png") == .logo)
    }

    @Test("모르는 이름과 확장자 없는 이름은 찾지 못한다")
    func rejectsUnknownFileName() {
        #expect(BrandingController.kind(forFileName: "favicon") == nil)
        #expect(BrandingController.kind(forFileName: "banner.png") == nil)
        #expect(BrandingController.kind(forFileName: "favicon.jpg") == nil)
    }

    /// 새 키를 뽑을 때마다 달라야 옛 그림이 캐시에 남지 않는다.
    @Test("올릴 때마다 새 자리를 잡는다")
    func objectKeyIsUnique() {
        let first = BrandingAsset.objectKey(kind: .logo)
        let second = BrandingAsset.objectKey(kind: .logo)
        #expect(first != second)
        #expect(first.hasPrefix("branding/logo-"))
        #expect(first.hasSuffix(".png"))
    }

    @Test("주소에 갱신 표시가 붙는다")
    func versionedPathCarriesStamp() {
        let asset = BrandingAsset(
            kind: .favicon, storageKey: "branding/favicon-x.png",
            contentType: "image/png", width: 512, height: 512, byteCount: 1024
        )
        asset.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(asset.versionedPath == "/branding/favicon.png?v=1700000000")
    }
}

@Suite("이미지 캐시")
struct StoredImageCacheTests {
    /// 파비콘은 화면을 그릴 때마다 요청된다. 그때마다 스토리지를 다녀오면 안 된다.
    @Test("같은 키는 한 번만 읽는다")
    func readsOnce() async throws {
        let cache = StoredImageCache()
        let counter = Counter()

        for _ in 0..<3 {
            _ = try await cache.data(forKey: "branding/logo-a.png") {
                await counter.increment()
                return Data(count: 100)
            }
        }
        #expect(await counter.value == 1)
    }

    @Test("키가 다르면 따로 읽는다")
    func separatesKeys() async throws {
        let cache = StoredImageCache()
        let counter = Counter()

        for key in ["branding/logo-a.png", "branding/logo-b.png"] {
            _ = try await cache.data(forKey: key) {
                await counter.increment()
                return Data(count: 100)
            }
        }
        #expect(await counter.value == 2)
    }

    /// 한 장이 캐시를 통째로 먹으면 캐시가 캐시 노릇을 못 한다. 그런 것은
    /// 내주기만 하고 들고 있지 않는다.
    @Test("너무 큰 그림은 들고 있지 않는다")
    func doesNotHoldHugeImages() async throws {
        let cache = StoredImageCache()
        let counter = Counter()
        let huge = Data(count: 31 * 1024 * 1024)

        for _ in 0..<2 {
            let data = try await cache.data(forKey: "branding/logo-huge.png") {
                await counter.increment()
                return huge
            }
            #expect(data.count == huge.count)
        }
        #expect(await counter.value == 2)
    }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
