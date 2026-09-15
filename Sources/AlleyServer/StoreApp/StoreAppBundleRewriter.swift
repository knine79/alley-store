import Foundation
import Vapor

/// CI 가 만든 브랜딩 없는 스토어 앱 번들을 이 조직의 것으로 다시 싼다 (ADR-0046).
///
/// **서버는 맥이 아니다.** 그런데도 이 일을 할 수 있는 것은 바꿔야 할 것이 전부
/// 파일 몇 개이기 때문이다. 컴파일도, 그림 변환도 필요 없다.
///
/// | 무엇 | 어떻게 |
/// | --- | --- |
/// | 번들 이름 (`Alley Store.app`) | zip 항목의 경로를 갈아끼운다 |
/// | 실행 파일 이름 | 같은 방법. `CFBundleExecutable` 과 이름이 같아야 한다 |
/// | `Info.plist` | 설정값으로 새로 쓴다 |
/// | `AppIcon.icns` | 올린 PNG 를 담아 넣는다 (`ICNSWriter`) |
/// | 임시 서명 | 통째로 버린다. 워커가 진짜 서명을 붙이며 다시 만든다 |
///
/// 나머지 - 실행 파일 수십 MB - 는 **압축된 바이트 그대로** 옮긴다(`ZipArchive`).
///
/// ## 왜 원본의 `Info.plist` 를 고치지 않고 새로 쓰나
///
/// 고치려면 plist 를 파싱해야 하고, 그 zip 항목은 압축돼 있어서 풀어야 한다.
/// 새로 쓰면 둘 다 필요 없다. 대신 **여기와 `scripts/build-store-app.sh` 가 같은
/// 키를 내야 한다.** 둘이 갈라지면 스크립트로 만든 번들과 서버가 만든 번들이
/// 다르게 동작한다. `StoreAppInfoPlistTests` 가 그것을 지킨다.
enum StoreAppBundleRewriter {
    /// 번들에 박을 값들.
    struct Branding: Sendable {
        var appName: String
        var bundleID: String
        var urlScheme: String
        var shortVersion: String
        var buildNumber: Int
        var minimumSystemVersion: String
        /// 이 빌드가 붙을 스토어 주소. 서버가 자기 주소를 안다 (ADR-0044).
        var serverURL: String?
        /// 올린 앱 아이콘 PNG 와 그 한 변. 없으면 아이콘 없이 나간다.
        var icon: (png: Data, edge: Int)?
    }

    enum RewriteError: Error, CustomStringConvertible {
        case noAppBundle(found: [String])
        case multipleAppBundles([String])

        var description: String {
            switch self {
            case .noAppBundle(let found):
                let sample = found.prefix(3).joined(separator: ", ")
                return """
                    zip 최상위에 `.app` 이 없습니다. CI 의 '스토어 앱 번들' 산출물을 \
                    올려주세요. 들어 있는 것: \(sample.isEmpty ? "(비어 있음)" : sample)
                    """
            case .multipleAppBundles(let names):
                return """
                    zip 최상위에 `.app` 이 여럿입니다: \(names.joined(separator: ", ")). \
                    번들 하나만 담긴 zip 이어야 어느 것을 쓸지 정할 수 있습니다.
                    """
            }
        }
    }

    /// 다시 싼 zip 을 돌려준다.
    static func rewrite(baseZip: Data, branding: Branding) throws -> Data {
        let entries = try ZipArchive.entries(in: baseZip)
        let source = try topLevelAppName(in: entries)

        let destination = "\(branding.appName).app"
        // 원본의 실행 파일 이름은 원본 번들 이름과 같다(`CFBundleExecutable`).
        // 그 규칙 위에서 이름 하나만 갈아끼운다.
        let sourceExecutable = "\(source)/Contents/MacOS/\(String(source.dropLast(4)))"
        let destinationExecutable = "\(destination)/Contents/MacOS/\(branding.appName)"

        var output: [ZipArchive.Entry] = []

        for entry in entries {
            // 임시 서명은 버린다. 파일을 하나라도 바꾸면 그 서명은 이미 틀린 것이고,
            // 남겨두면 워커의 `codesign --force` 가 덮기 전까지 "서명이 깨진 번들" 로
            // 보인다. 판정이 그 사이에 끼면 무엇을 본 것인지 알 수 없다.
            if entry.name.contains("/_CodeSignature/") { continue }
            // 우리가 새로 쓰는 것들. 원본 것은 버린다.
            if entry.name == "\(source)/Contents/Info.plist" { continue }
            if entry.name == "\(source)/Contents/Resources/AppIcon.icns" { continue }

            var moved = entry
            if entry.name == sourceExecutable {
                moved.name = destinationExecutable
            } else if entry.name.hasPrefix("\(source)/") {
                moved.name = destination + entry.name.dropFirst(source.count)
            } else if entry.name == source || entry.name == "\(source)/" {
                moved.name = "\(destination)/"
            }
            output.append(moved)
        }

        output.append(
            ZipArchive.stored(
                name: "\(destination)/Contents/Info.plist",
                data: Data(infoPlist(branding).utf8)
            )
        )

        if let icon = branding.icon {
            output.append(
                ZipArchive.stored(
                    name: "\(destination)/Contents/Resources/AppIcon.icns",
                    data: try ICNSWriter.icns(png: icon.png, edge: icon.edge)
                )
            )
        }

        return ZipArchive.write(output)
    }

    /// zip 최상위의 `.app` 이름을 찾는다.
    static func topLevelAppName(in entries: [ZipArchive.Entry]) throws -> String {
        let tops = Set(
            entries.compactMap { $0.name.split(separator: "/").first.map(String.init) }
        )
        let bundles = tops.filter { $0.hasSuffix(".app") }.sorted()

        switch bundles.count {
        case 1: return bundles[0]
        case 0: throw Abort(.badRequest, reason: RewriteError.noAppBundle(found: tops.sorted()).description)
        default: throw Abort(.badRequest, reason: RewriteError.multipleAppBundles(bundles).description)
        }
    }

    // MARK: - Info.plist

    /// **`scripts/build-store-app.sh` 와 같은 키를 내야 한다.**
    ///
    /// 그 스크립트는 셸이라 이 코드를 부를 수 없다. 두 벌이 존재하는 것을 없앨 수는
    /// 없으니, 대신 갈라지는 것을 시험이 잡는다(`StoreAppInfoPlistTests`).
    static func infoPlist(_ branding: Branding) -> String {
        var entries = """
                <key>CFBundleName</key>
                <string>\(escaped(branding.appName))</string>
                <key>CFBundleDisplayName</key>
                <string>\(escaped(branding.appName))</string>
                <key>CFBundleIdentifier</key>
                <string>\(escaped(branding.bundleID))</string>
                <key>CFBundleExecutable</key>
                <string>\(escaped(branding.appName))</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleShortVersionString</key>
                <string>\(escaped(branding.shortVersion))</string>
                <key>CFBundleVersion</key>
                <string>\(branding.buildNumber)</string>
                <key>LSMinimumSystemVersion</key>
                <string>\(escaped(branding.minimumSystemVersion))</string>
                <key>LSUIElement</key>
                <false/>
            """

        if branding.icon != nil {
            // 확장자 없이 적는다. macOS 가 `.icns` 를 붙여 찾는다.
            entries += """

                    <key>CFBundleIconFile</key>
                    <string>AppIcon</string>
                """
        }

        if let serverURL = branding.serverURL, !serverURL.isEmpty {
            entries += """

                    <key>AlleyServerURL</key>
                    <string>\(escaped(serverURL))</string>
                """
        }

        entries += """

                <key>CFBundleURLTypes</key>
                <array>
                    <dict>
                        <key>CFBundleURLName</key>
                        <string>\(escaped(branding.bundleID))</string>
                        <key>CFBundleURLSchemes</key>
                        <array>
                            <string>\(escaped(branding.urlScheme))</string>
                        </array>
                    </dict>
                </array>
            """

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \(entries)
            </dict>
            </plist>

            """
    }

    /// 앱 이름은 사람이 적는 값이라 `&` 나 `<` 가 들어올 수 있다. 그대로 넣으면
    /// plist 가 깨지고, 깨진 plist 를 가진 번들은 실행되지 않는다.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
