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
        try FileManager.default.createSymbolicLink(
            atPath: resources.appendingPathComponent("Current").path,
            withDestinationPath: "."
        )

        let archive = root.appendingPathComponent("bundle.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        return (try Data(contentsOf: archive), root)
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
                icon: (PNGFixture.png(width: 1024, height: 1024), 1024)
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
        let executable = app.appendingPathComponent("Contents/MacOS/우리 스토어")

        #expect(FileManager.default.fileExists(atPath: executable.path))
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        // plist 가 진짜로 읽히는지는 plutil 이 판정한다. 우리가 문자열을 맞춰본
        // 것과 macOS 가 파싱할 수 있는 것은 다른 이야기다.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try Self.run("/usr/bin/plutil", ["-lint", plist.path])

        let parsed = try #require(
            NSDictionary(contentsOf: plist) as? [String: Any]
        )
        #expect(parsed["CFBundleExecutable"] as? String == "우리 스토어")
        #expect(parsed["CFBundleIdentifier"] as? String == "com.example.alley.store")
        #expect(parsed["CFBundleIconFile"] as? String == "AppIcon")
        #expect(parsed["AlleyServerURL"] as? String == "https://store.example.com")

        #expect(
            FileManager.default.fileExists(
                atPath: app.appendingPathComponent("Contents/Resources/AppIcon.icns").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: app.appendingPathComponent("Contents/_CodeSignature").path
            )
        )
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
