import AppKit
import Foundation

/// 앱 아이콘을 받아 투명한 여백을 걷어낸다.
///
/// **그대로 그리면 아이콘마다 크기가 달라 보인다.** macOS 아이콘은 보통 캔버스 둘레에
/// 투명한 여백과 그림자를 두고 그림을 안쪽에 그린다(1024 캔버스에 824 정도). 반면 여백
/// 없이 꽉 찬 아이콘도 있다. 같은 칸에 넣으면 앞쪽은 작게, 뒤쪽은 크게 보인다. 여백을
/// 걷어내고 그림만 칸에 맞추면 둘이 같은 크기로 보인다.
///
/// 받은 것은 주소별로 들고 있는다. 목록과 상세가 같은 아이콘을 여러 번 그린다.
@MainActor
final class IconImages {
    static let shared = IconImages()

    private var images: [URL: NSImage] = [:]
    private var pending: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = images[url] { return cached }
        if let running = pending[url] { return await running.value }

        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return Self.trimmed(data)
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        if let image { images[url] = image }
        return image
    }

    /// 그림 데이터에서 투명한 여백을 걷어낸 것. 읽지 못하면 nil, 걷어낼 것이 없으면 그대로.
    nonisolated static func trimmed(_ data: Data) -> NSImage? {
        guard let source = NSImage(data: data),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }
        guard let bounds = opaqueBounds(of: cgImage),
              bounds.size != CGSize(width: cgImage.width, height: cgImage.height),
              let cropped = cgImage.cropping(to: bounds)
        else {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// 그림이 실제로 있는 영역. 원본 픽셀 좌표(위가 0)다. 전부 투명하면 nil.
    ///
    /// **반투명은 여백으로 친다.** macOS 아이콘의 그림자는 반쯤 투명해서, 그것까지 그림으로
    /// 치면 그림자가 있는 아이콘만 작게 보인다. 판단은 256 으로 줄여서 한다. 1024 그대로
    /// 훑을 이유가 없다.
    nonisolated static func opaqueBounds(of image: CGImage, alphaThreshold: UInt8 = 128) -> CGRect? {
        let side = 256
        let scaleX = Double(image.width) / Double(side)
        let scaleY = Double(image.height) / Double(side)
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // 비트맵 메모리는 첫 줄이 그림의 위쪽이다.
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where pixels[(y * side + x) * 4 + 3] >= alphaThreshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: (Double(minX) * scaleX).rounded(.down),
            y: (Double(minY) * scaleY).rounded(.down),
            width: (Double(maxX - minX + 1) * scaleX).rounded(.up),
            height: (Double(maxY - minY + 1) * scaleY).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
