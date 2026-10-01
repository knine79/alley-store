#if canImport(AppKit)
import AppKit
import Foundation
import Testing

@testable import AlleyWorkerCore

@Suite("앱 아이콘 뽑기 (ADR-0067)")
struct AppIconTests {
    @Test("번들의 .icns 를 정해진 크기의 PNG 로 뽑는다")
    func rendersDeclaredIcon() throws {
        let fixture = try BundleFixture()
        let app = try makeApp(in: fixture, iconFile: "AppIcon", color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))

        let png = try #require(AppIcon.png(forBundleAt: app))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(bitmap.pixelsWide == AppIcon.edge)
        #expect(bitmap.pixelsHigh == AppIcon.edge)

        // 번들에 넣은 그림 그대로여야 한다. 일반 앱 아이콘이나, 이 맥에서 못 여는 앱에
        // `NSWorkspace` 가 덧씌우는 금지 표시가 끼면 가운데가 빨갛지 않다.
        let center = try #require(
            bitmap.colorAt(x: AppIcon.edge / 2, y: AppIcon.edge / 2)?.usingColorSpace(.deviceRGB)
        )
        #expect(center.redComponent > 0.8)
        #expect(center.greenComponent < 0.3)
    }

    /// 아이콘을 밝히지 않은 번들에서 일반 앱 아이콘을 뽑아 걸면 진짜 아이콘처럼 보여서
    /// "없다" 보다 나쁘다.
    @Test("아이콘을 밝히지 않은 번들은 뽑지 않는다")
    func skipsBundleWithoutIcon() throws {
        let fixture = try BundleFixture()
        let app = try makeApp(in: fixture, iconFile: nil, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))

        #expect(AppIcon.png(forBundleAt: app) == nil)
    }

    // MARK: - 픽스처

    /// 단색 PNG 하나를 `ic09`(512) 자리에 담은 `.icns` 를 가진 번들.
    private func makeApp(in fixture: borrowing BundleFixture, iconFile: String?, color: NSColor) throws -> URL {
        let app = try fixture.makeDirectory("Sample.app")
        let resources = try fixture.makeDirectory("Sample.app/Contents/Resources")

        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample",
            "CFBundleExecutable": "Sample",
            "CFBundlePackageType": "APPL",
        ]
        if let iconFile {
            plist["CFBundleIconFile"] = iconFile
            try icns(png: png(edge: 512, color: color))
                .write(to: resources.appendingPathComponent("\(iconFile).icns"))
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fixture.makeMachO("Sample.app/Contents/MacOS/Sample")
        return app
    }

    private func png(edge: Int, color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: edge, height: edge).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// `'icns' | 전체 길이 | 'ic09' | 항목 길이 | PNG`. 길이는 빅엔디언이고 머리 8바이트를 포함한다.
    private func icns(png: Data) -> Data {
        func be32(_ value: Int) -> Data {
            withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
        }
        var data = Data("icns".utf8)
        data.append(be32(8 + 8 + png.count))
        data.append(Data("ic09".utf8))
        data.append(be32(8 + png.count))
        data.append(png)
        return data
    }
}
#endif
