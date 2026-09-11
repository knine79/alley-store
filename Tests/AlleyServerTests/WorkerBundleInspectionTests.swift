import Foundation
import Testing
import Vapor

@testable import AlleyServer

/// 올라온 zip 이 정말 워커 번들인지 본다 (ADR-0042).
///
/// 설치 키트(`alley-worker-kit.zip`)를 잘못 올리는 일이 흔하다. 그것도 zip 이라
/// 예전에는 그냥 통과했고, 잘못됐다는 사실은 10분 뒤 워커 로그에만 남았다.
@Suite("워커 번들 검사")
struct WorkerBundleInspectionTests {
    /// 이름만 든 zip 을 만든다. 내용은 이 검사가 보지 않는다.
    ///
    /// `Process` 로 `zip`(1) 을 부르지 않는 이유는 리눅스 CI 에도 있어야 하고,
    /// 무엇보다 **검사가 읽는 것은 목차뿐** 이라 목차만 맞으면 된다.
    @Test("목차를 읽는다")
    func readsEntryNames() throws {
        let data = ZipFixture.zip(names: [
            "alley-worker.app/", "alley-worker.app/Contents/Info.plist",
        ])
        let names = try WorkerBundleInspection.entryNames(in: data)
        #expect(names.contains("alley-worker.app/Contents/Info.plist"))
    }

    @Test("최상위에 .app 이 있으면 통과한다")
    func acceptsBundleZip() throws {
        let data = ZipFixture.zip(names: [
            "alley-worker.app/",
            "alley-worker.app/Contents/MacOS/alley-worker",
            "alley-worker.app/Contents/Info.plist",
        ])
        try WorkerBundleInspection.requireTopLevelApp(in: data)
    }

    /// **이것이 이 검사를 만든 이유다.** 키트도 zip 이라 예전에는 통과했다.
    @Test("설치 키트를 올리면 무엇을 올려야 하는지 말한다")
    func rejectsKitZipWithGuidance() throws {
        let data = ZipFixture.zip(names: [
            "kit/",
            "kit/install-worker.sh",
            "kit/alley-worker.app/Contents/Info.plist",
        ])

        do {
            try WorkerBundleInspection.requireTopLevelApp(in: data)
            Issue.record("키트를 통과시켰다")
        } catch let abort as any AbortError {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("한 겹 안에 있습니다"))
            #expect(abort.reason.contains("alley-worker.zip"))
        }
    }

    @Test("앱이 아예 없으면 거절한다")
    func rejectsZipWithoutApp() throws {
        let data = ZipFixture.zip(names: ["readme.txt", "src/main.swift"])

        do {
            try WorkerBundleInspection.requireTopLevelApp(in: data)
            Issue.record("앱 없는 zip 을 통과시켰다")
        } catch let abort as any AbortError {
            #expect(abort.reason.contains("최상위에 `.app` 이 없습니다"))
        }
    }

    @Test("빈 zip 은 거절한다")
    func rejectsEmptyZip() throws {
        #expect(throws: (any Error).self) {
            try WorkerBundleInspection.requireTopLevelApp(in: ZipFixture.zip(names: []))
        }
    }

    /// 목차를 못 찾으면 파일이 잘린 것이다. 그 사실을 말해준다.
    @Test("목차가 없으면 잘렸다고 말한다")
    func rejectsTruncated() throws {
        let data = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x00, count: 200)

        do {
            try WorkerBundleInspection.requireTopLevelApp(in: data)
            Issue.record("잘린 zip 을 통과시켰다")
        } catch let abort as any AbortError {
            #expect(abort.reason.contains("잘린"))
        }
    }
}
