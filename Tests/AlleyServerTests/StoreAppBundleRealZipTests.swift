#if os(macOS)
import Foundation
import Testing

@testable import AlleyServer

/// 진짜 도구가 만든 zip 을 진짜 도구로 다시 풀어본다.
///
/// 합성 zip 만으로는 부족하다. 우리가 쓴 zip 을 우리가 읽으면, 형식을 똑같이
/// 오해하고 있어도 통과한다. **번들을 싸는 것은 `ditto` 이고 푸는 것은 워커의
/// `ditto`** 이므로, 그 둘 사이에서 성립해야 의미가 있다.
///
/// macOS 에서만 돈다. 리눅스 CI 에는 `ditto` 가 없고, 그 잡이 도는 자리에서는 이
/// 조립이 실제로 쓰이지도 않는다. CI 의 macOS 잡이 이 시험을 돌린다.
@Suite("스토어 앱 번들 조립 (진짜 zip)")
struct StoreAppBundleRealZipTests {
    /// `.app` 모양을 갖춘 디렉터리를 만들고 `ditto` 로 싼다.
    ///
    /// 실제 스토어 앱 번들을 쓰지 않는 이유는 그것이 release 빌드를 요구해서다.
    /// 여기서 확인하려는 것은 **zip 형식을 주고받는 일** 이지 실행 파일의 내용이
    /// 아니다. 대신 `ditto` 가 실제로 만드는 항목 - 디렉터리, 실행 비트, 심볼릭
    /// 링크 - 은 그대로 들어간다.
    static func makeBundleZip(named name: String) throws -> (zip: Data, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alley-zip-\(UUID().uuidString)")
        let app = root.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        let signature = app.appendingPathComponent("Contents/_CodeSignature")

        for directory in [macOS, resources, signature] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let executable = macOS.appendingPathComponent(name)
        try Data("#!/bin/sh\necho 실행 파일\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try Data("<plist>옛것</plist>".utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("임시 서명".utf8)
            .write(to: signature.appendingPathComponent("CodeResources"))
        // 프레임워크 번들에 흔한 심볼릭 링크. 옮기다 망가뜨리면 서명이 깨진다.
        //
        // 대상을 같은 자리의 파일로 둔다. `.` 을 가리키면 자기 자신으로 도는 고리가
        // 되고, `codesign` 이 그것을 `unsealed contents present in the bundle root`
        // 로 거절한다. 실제 번들에 그런 링크는 없다.
        try Data("자료".utf8).write(to: resources.appendingPathComponent("data.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: resources.appendingPathComponent("Current").path,
            withDestinationPath: "data.txt"
        )

        let archive = root.appendingPathComponent("bundle.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        return (try Data(contentsOf: archive), root)
    }

    /// 진짜 PNG 한 장. macOS 가 들고 있는 아이콘을 줄여서 만든다.
    ///
    /// `PNGFixture` 는 머리 24바이트만 있는 가짜라 `iconutil` 이 읽지 못한다. 그것으로
    /// 만든 `.icns` 는 우리 시험은 통과하고 macOS 는 거절하는데, 그 차이가 드러나는
    /// 자리가 바로 여기다.
    static func realPNG(in directory: URL) throws -> Data {
        let source = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
        let output = directory.appendingPathComponent("icon.png")
        try run("/usr/bin/sips", ["-s", "format", "png", "-z", "1024", "1024", source, "--out", output.path])
        return try Data(contentsOf: output)
    }

    @Test("ditto 가 싼 것을 읽어 다시 쓰면 unzip 이 푼다")
    func roundTripsThroughRealTools() throws {
        let (baseZip, root) = try Self.makeBundleZip(named: "Alley Store")
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try StoreAppBundleRewriter.rewrite(
            baseZip: baseZip,
            branding: StoreAppBundleRewriter.Branding(
                appName: "우리 스토어",
                bundleID: "com.example.alley.store",
                urlScheme: "examplestore",
                shortVersion: "0.4.0",
                buildNumber: 7,
                minimumSystemVersion: "14.0",
                serverURL: "https://store.example.com",
                icon: (try Self.realPNG(in: root), 1024)
            )
        )

        let rewritten = root.appendingPathComponent("rewritten.zip")
        try output.write(to: rewritten)

        // **`unzip -t` 가 이 시험의 핵심이다.** 우리가 쓴 목차와 로컬 헤더가
        // 어긋나 있으면 여기서 걸린다. 우리 코드로 다시 읽는 것만으로는 같은
        // 오해를 두 번 하고 통과할 수 있다.
        try Self.run("/usr/bin/unzip", ["-tqq", rewritten.path])

        let unpacked = root.appendingPathComponent("unpacked")
        try Self.run("/usr/bin/unzip", ["-qq", rewritten.path, "-d", unpacked.path])

        let app = unpacked.appendingPathComponent("우리 스토어.app")
        // 폴더 이름은 한글이어도 되지만 실행 파일은 ASCII 여야 한다
        // (`StoreAppBundleRewriter.executableName(for:)`).
        let executable = app.appendingPathComponent("Contents/MacOS/AlleyStore")

        #expect(FileManager.default.fileExists(atPath: executable.path))
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        // plist 가 진짜로 읽히는지는 plutil 이 판정한다. 우리가 문자열을 맞춰본
        // 것과 macOS 가 파싱할 수 있는 것은 다른 이야기다.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try Self.run("/usr/bin/plutil", ["-lint", plist.path])

        let parsed = try #require(
            NSDictionary(contentsOf: plist) as? [String: Any]
        )
        #expect(parsed["CFBundleExecutable"] as? String == "AlleyStore")
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.alley.store")
        #expect(parsed["CFBundleIconFile"] as? String == "AppIcon")
        #expect(parsed["AlleyServerURL"] as? String == "https://store.example.com")
        // 사람에게 보이는 이름은 적은 그대로다. 바꾼 것은 실행 파일 이름뿐이다.
        #expect(parsed["CFBundleDisplayName"] as? String == "우리 스토어")

        #expect(
            !FileManager.default.fileExists(
                atPath: app.appendingPathComponent("Contents/_CodeSignature").path
            )
        )

        // 아이콘이 진짜 `.icns` 인가. 우리가 바이트를 맞춰본 것과 macOS 가 읽을 수
        // 있는 것은 다른 이야기다.
        try Self.run(
            "/usr/bin/iconutil",
            [
                "-c", "iconset",
                "-o", root.appendingPathComponent("out.iconset").path,
                app.appendingPathComponent("Contents/Resources/AppIcon.icns").path,
            ]
        )

        // **여기가 이 시험의 핵심이다.** 워커가 하는 일을 흉내낸다.
        //
        // 실행 파일 이름에 비ASCII 문자가 있으면 `--verify --deep --strict` 가
        // `a sealed resource is missing or invalid` 로 거절한다. 그 실패는 서명이
        // 끝난 뒤에야 나오고 문구만으로는 이름이 원인이라는 것을 알 수 없다.
        // 한글 이름으로 빌드하는 조직은 그 이유로 스토어 앱을 영영 내보내지 못한다.
        try Self.run(
            "/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", app.path]
        )
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }


    static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()

        // 읽기 전에 기다리면 파이프 버퍼가 차서 멈출 수 있다. 여기 출력은 짧지만
        // 워커에서 실제로 그 경합에 걸린 적이 있어서 순서를 지킨다.
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RunFailure(
                command: "\(launchPath) \(arguments.joined(separator: " "))",
                status: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
            )
        }
    }

    struct RunFailure: Error, CustomStringConvertible {
        var command: String
        var status: Int32
        var message: String

        var description: String { "\(command) 가 \(status) 로 끝났습니다: \(message)" }
    }
}
#endif
