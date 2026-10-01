import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// 번들의 앱 아이콘을 PNG 로 뽑는다 (ADR-0067).
///
/// **`.icns` 만 보지 않는다.** 그러면 `Assets.car` 에만 아이콘이 든 번들
/// (`CFBundleIconName`, Icon Composer)을 놓친다. 브라우저가 놓치던 것이 바로 그것이다.
/// `Bundle.image(forResource:)` 는 에셋 카탈로그와 `.icns` 를 함께 찾는다.
///
/// **`NSWorkspace.icon(forFile:)` 을 쓰지 않는다.** 그쪽은 이 맥에서 실행할 수 없는
/// 앱이라고 보면 아이콘 위에 금지 표시를 덧씌운다. 워커 맥의 macOS 가 앱의 최소 OS
/// 보다 낮으면 그 그림이 그대로 스토어에 걸린다. 시험 픽스처로 실제로 그렇게 나왔다.
enum AppIcon {
    /// 뽑을 크기. 스토어 목록과 상세는 이보다 작게 그린다. 1024 는 용량만 커진다.
    static let edge = 512

    /// 아이콘을 PNG 로. 아이콘이 없거나 그리지 못하면 nil 이다.
    ///
    /// 실패를 던지지 않는다. 아이콘이 없다고 서명을 실패시킬 이유가 없다.
    static func png(forBundleAt url: URL) -> Data? {
        #if canImport(AppKit)
        guard let bundle = Bundle(url: url) else { return nil }
        for name in iconNames(bundleAt: url) {
            if let image = bundle.image(forResource: name) {
                return render(image, edge: edge)
            }
        }
        #endif
        return nil
    }

    /// `Info.plist` 가 가리키는 아이콘 이름들. 찾아볼 순서대로다.
    ///
    /// `CFBundleIconName`(에셋 카탈로그)이 먼저다. 둘 다 있는 번들에서 macOS 26 이
    /// 그리는 것이 그쪽이다. 아무것도 가리키지 않으면 뽑지 않는다. 일반 앱 아이콘을
    /// 앱 아이콘으로 걸면 "아이콘이 없다" 보다 나쁘다. 진짜처럼 보여서다.
    static func iconNames(bundleAt url: URL) -> [String] {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        return ["CFBundleIconName", "CFBundleIconFile"].compactMap {
            AppBundle.string($0, fromInfoPlistAt: plist)
        }
    }

    #if canImport(AppKit)
    /// 정해진 크기의 비트맵에 그려 PNG 로 굽는다.
    ///
    /// `NSImage` 의 기본 크기는 32pt 라 그대로 꺼내면 작게 나온다. 그릴 자리를 정해주면
    /// 그 크기에 맞는 표현을 골라 그린다.
    private static func render(_ image: NSImage, edge: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: edge,
            pixelsHigh: edge,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        bitmap.size = NSSize(width: edge, height: edge)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: edge, height: edge),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }
    #endif
}
