import Foundation
import Testing

@testable import AlleyWorkerCore

/// 임시 디렉터리에 가짜 앱 번들을 만든다.
///
/// 실제 Mach-O 는 아니지만 앞 4바이트가 같으면 우리 판별기에는 실행 파일이다.
/// 서명 순서를 확인하는 데는 그것으로 충분하다.
struct BundleFixture: ~Copyable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeDirectory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func makeMachO(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // 64비트 Mach-O 의 매직 넘버.
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x00, 0x00]).write(to: url)
        return url
    }

    @discardableResult
    func makeFile(_ path: String, contents: String = "리소스") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// `CFBundleExecutable` 만 담은 Info.plist.
    @discardableResult
    func makeInfoPlist(_ path: String, executable: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": executable],
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        return url
    }

    @discardableResult
    func makeSymbolicLink(_ path: String, to destination: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: url.path, withDestinationPath: destination
        )
        return url
    }

    /// Electron 이 만드는 것과 같은 모양의 프레임워크.
    ///
    /// 주 실행 파일 하나에 dylib 과 헬퍼 도구가 딸려 있고, 바깥에서 안쪽을 가리키는
    /// 심볼릭 링크가 있다. 실제로 이 모양에서 서명이 새어 나갔다.
    func makeVersionedFramework(at path: String, named name: String) throws {
        try makeMachO("\(path)/Versions/A/\(name)")
        try makeMachO("\(path)/Versions/A/Libraries/libGLESv2.dylib")
        try makeMachO("\(path)/Versions/A/Helpers/crashpad_handler")
        try makeFile("\(path)/Versions/A/Resources/icon.png")
        try makeSymbolicLink("\(path)/Versions/Current", to: "A")
        try makeSymbolicLink("\(path)/\(name)", to: "Versions/Current/\(name)")
    }
}

@Suite("Mach-O 판별")
struct MachODetectionTests {
    @Test("실행 파일의 매직 넘버를 알아본다", arguments: [
        [0xCF, 0xFA, 0xED, 0xFE] as [UInt8],  // 64비트
        [0xFE, 0xED, 0xFA, 0xCF],
        [0xCE, 0xFA, 0xED, 0xFE],  // 32비트
        [0xCA, 0xFE, 0xBA, 0xBE],  // universal
    ])
    func recognizesMachO(_ bytes: [UInt8]) {
        // 헬퍼 도구는 확장자가 없는 경우가 대부분이라 앞 4바이트로 판별한다.
        #expect(AppBundle.isMachO(magic: Data(bytes)))
    }

    @Test("실행 파일이 아닌 것은 거른다", arguments: [
        [0x89, 0x50, 0x4E, 0x47] as [UInt8],  // PNG
        [0x3C, 0x3F, 0x78, 0x6D],  // <?xm
        [0x00, 0x00, 0x00],  // 너무 짧다
    ])
    func rejectsOtherFiles(_ bytes: [UInt8]) {
        #expect(!AppBundle.isMachO(magic: Data(bytes)))
    }
}

@Suite("서명 대상 수집")
struct CodeToSignTests {
    @Test("앱은 언제나 마지막에 서명한다")
    func appIsSignedLast() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        _ = try fixture.makeDirectory("도구.app/Contents/Frameworks/Shared.framework")
        try fixture.makeMachO("도구.app/Contents/Frameworks/Shared.framework/Shared")

        let targets = try AppBundle(url: app).codeToSign()

        // 프레임워크를 나중에 서명하면 앱의 봉인이 깨진다.
        #expect(targets.last == app)
        #expect(targets.count == 2)
        #expect(targets.first?.lastPathComponent == "Shared.framework")
    }

    @Test("깊은 것부터 서명한다")
    func deepestFirst() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        _ = try fixture.makeDirectory("도구.app/Contents/Frameworks/Outer.framework")
        _ = try fixture.makeDirectory(
            "도구.app/Contents/Frameworks/Outer.framework/Frameworks/Inner.framework"
        )

        let targets = try AppBundle(url: app).codeToSign()
        let names = targets.map(\.lastPathComponent)

        #expect(names.firstIndex(of: "Inner.framework")! < names.firstIndex(of: "Outer.framework")!)
    }

    @Test("번들 안의 실행 파일은 따로 세지 않는다")
    func skipsExecutablesInsideBundles() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        _ = try fixture.makeDirectory("도구.app/Contents/Frameworks/Shared.framework")
        try fixture.makeMachO("도구.app/Contents/Frameworks/Shared.framework/Shared")
        try fixture.makeMachO("도구.app/Contents/Frameworks/Shared.framework/Versions/A/Shared")

        let targets = try AppBundle(url: app).codeToSign()

        // 프레임워크를 서명하면 그 안은 함께 봉인된다. 따로 서명하면 같은 것을 두 번 한다.
        #expect(targets.count == 2)
    }

    @Test("홀로 놓인 헬퍼 실행 파일은 따로 서명한다")
    func signsLooseHelpers() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        try fixture.makeMachO("도구.app/Contents/Helpers/updater")

        let targets = try AppBundle(url: app).codeToSign()

        // 자기 서명이 없으면 이 헬퍼는 실행되지 않는다.
        #expect(targets.map(\.lastPathComponent).contains("updater"))
    }

    @Test("프레임워크 안의 dylib 과 헬퍼는 따로 서명한다")
    func signsCodeInsideFrameworks() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        try fixture.makeVersionedFramework(
            at: "도구.app/Contents/Frameworks/Electron.framework", named: "Electron"
        )

        let names = try AppBundle(url: app).codeToSign().map(\.lastPathComponent)

        // 프레임워크를 서명해도 이것들의 서명은 바뀌지 않는다. 링커가 붙인 ad-hoc 서명이
        // 그대로 남아 공증에서 거절당한다.
        #expect(names.contains("libGLESv2.dylib"))
        #expect(names.contains("crashpad_handler"))
    }

    @Test("프레임워크 안쪽을 프레임워크보다 먼저 서명한다")
    func signsFrameworkContentsFirst() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        try fixture.makeVersionedFramework(
            at: "도구.app/Contents/Frameworks/Electron.framework", named: "Electron"
        )

        let names = try AppBundle(url: app).codeToSign().map(\.lastPathComponent)
        let framework = names.firstIndex(of: "Electron.framework")!

        // 순서가 뒤집히면 프레임워크의 봉인이 깨진다.
        #expect(names.firstIndex(of: "libGLESv2.dylib")! < framework)
        #expect(names.firstIndex(of: "crashpad_handler")! < framework)
    }

    @Test("프레임워크의 주 실행 파일은 따로 서명하지 않는다")
    func skipsFrameworkMainExecutable() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        try fixture.makeVersionedFramework(
            at: "도구.app/Contents/Frameworks/Electron.framework", named: "Electron"
        )

        let targets = try AppBundle(url: app).codeToSign()

        // 프레임워크와 함께 봉인된다. 따로 서명하면 그 봉인이 깨진다.
        #expect(!targets.contains { $0.path.hasSuffix("Versions/A/Electron") })
        // 바깥에서 안쪽을 가리키는 링크도 같은 파일이다.
        #expect(!targets.contains { $0.path.hasSuffix("Electron.framework/Electron") })
    }

    @Test("Info.plist 가 정한 이름을 주 실행 파일로 본다")
    func honorsDeclaredExecutableName() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/실행기")
        try fixture.makeInfoPlist("도구.app/Contents/Info.plist", executable: "실행기")

        let targets = try AppBundle(url: app).codeToSign()

        // 번들 이름과 실행 파일 이름이 다른 앱이 흔하다.
        #expect(targets.map(\.lastPathComponent) == [app.lastPathComponent])
    }

    @Test("모든 Mach-O 를 세는 쪽은 주 실행 파일도 포함한다")
    func countsEveryMachO() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        try fixture.makeVersionedFramework(
            at: "도구.app/Contents/Frameworks/Electron.framework", named: "Electron"
        )

        let names = AppBundle(url: app).allMachOFiles().map(\.lastPathComponent).sorted()

        // 서명이 끝난 뒤 빠뜨린 것을 찾는 데 쓴다. 서명 대상을 고르는 논리를 다시 쓰면
        // 그 논리의 실수를 잡을 수 없다.
        #expect(names == ["Electron", "crashpad_handler", "libGLESv2.dylib", "도구"])
    }

    @Test("리소스는 서명 대상이 아니다")
    func ignoresResources() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeMachO("도구.app/Contents/MacOS/도구")
        try fixture.makeFile("도구.app/Contents/Info.plist", contents: "<plist/>")
        try fixture.makeFile("도구.app/Contents/Resources/icon.png")

        let targets = try AppBundle(url: app).codeToSign()

        #expect(targets.map(\.lastPathComponent) == [app.lastPathComponent])
    }
}

@Suite("앱 번들 찾기")
struct LocateBundleTests {
    @Test("풀어놓은 디렉터리에서 앱 하나를 찾는다")
    func findsSingleApp() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")

        // 경로 표기가 다를 수 있어(/var 와 /private/var) 문자열 그대로 비교하지 않는다.
        let found = try AppBundle.locate(in: fixture.root).url
        #expect(found.lastPathComponent == app.lastPathComponent)
    }

    @Test("앱이 없으면 무엇이 잘못됐는지 알려준다")
    func reportsMissingApp() throws {
        let fixture = try BundleFixture()
        try fixture.makeFile("readme.txt")

        #expect(throws: AppBundle.BundleError.self) {
            try AppBundle.locate(in: fixture.root)
        }
    }

    @Test("앱이 여러 개면 고르지 않는다")
    func refusesAmbiguousArchive() throws {
        let fixture = try BundleFixture()
        _ = try fixture.makeDirectory("하나.app")
        _ = try fixture.makeDirectory("둘.app")

        // 어느 것을 배포할지 우리가 정할 수 없다.
        #expect(throws: AppBundle.BundleError.self) {
            try AppBundle.locate(in: fixture.root)
        }
    }
}
