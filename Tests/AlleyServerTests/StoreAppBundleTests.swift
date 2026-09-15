import Foundation
import Testing
import Vapor

@testable import AlleyServer

@Suite("zip 다시 쓰기")
struct ZipArchiveTests {
    /// 널리 쓰이는 검사값. "123456789" 의 CRC32 는 0xCBF43926 이다.
    /// 표를 잘못 만들면 여기서 바로 드러난다.
    @Test("CRC32 가 알려진 값과 같다")
    func crcMatchesKnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("쓴 것을 그대로 다시 읽는다")
    func roundTrip() throws {
        let written = ZipArchive.write([
            ZipArchive.stored(name: "Thing.app/", data: Data(), mode: 0o755),
            ZipArchive.stored(name: "Thing.app/Contents/Info.plist", data: Data("plist".utf8)),
            ZipArchive.stored(
                name: "Thing.app/Contents/MacOS/Thing", data: Data("binary".utf8), mode: 0o755
            ),
        ])

        let read = try ZipArchive.entries(in: written)
        #expect(read.map(\.name) == [
            "Thing.app/", "Thing.app/Contents/Info.plist", "Thing.app/Contents/MacOS/Thing",
        ])
        #expect(read[1].compressedData == Data("plist".utf8))
    }

    /// **실행 비트를 잃으면 앱이 실행되지 않는다.** 그 사실은 서명·공증을 다 마치고
    /// 사람이 앱을 두 번 눌렀을 때 드러난다.
    @Test("실행 권한이 살아남는다")
    func preservesExecutableBit() throws {
        let written = ZipArchive.write([
            ZipArchive.stored(name: "Thing.app/Contents/MacOS/Thing", data: Data("x".utf8), mode: 0o755)
        ])
        let mode = try ZipArchive.entries(in: written)[0].externalAttributes >> 16
        #expect(mode & 0o777 == 0o755)
    }

    @Test("zip 이 아니면 거절한다")
    func rejectsNonZip() {
        #expect(throws: (any Error).self) {
            try ZipArchive.entries(in: Data("not a zip at all, not even close!!".utf8))
        }
    }
}

@Suite("스토어 앱 번들 조립")
struct StoreAppBundleRewriterTests {
    /// CI 가 내놓는 모양을 흉내낸 번들.
    ///
    /// 임시 서명(`_CodeSignature`)까지 넣는 것은 그것이 실제로 들어 있고, 조립이
    /// 그것을 버리는지가 이 시험의 핵심 중 하나이기 때문이다.
    static func baseZip(appName: String = "Alley Store") -> Data {
        ZipArchive.write([
            ZipArchive.stored(name: "\(appName).app/", data: Data(), mode: 0o755),
            ZipArchive.stored(
                name: "\(appName).app/Contents/MacOS/\(appName)",
                data: Data("실행 파일이라고 치자".utf8), mode: 0o755
            ),
            ZipArchive.stored(
                name: "\(appName).app/Contents/Info.plist", data: Data("<plist>옛것</plist>".utf8)
            ),
            ZipArchive.stored(
                name: "\(appName).app/Contents/_CodeSignature/CodeResources",
                data: Data("임시 서명".utf8)
            ),
        ])
    }

    static func branding(
        appName: String = "우리 스토어",
        icon: (png: Data, edge: Int)? = nil,
        serverURL: String? = nil
    ) -> StoreAppBundleRewriter.Branding {
        StoreAppBundleRewriter.Branding(
            appName: appName,
            bundleID: "com.example.alley.store",
            urlScheme: "examplestore",
            shortVersion: "0.4.0",
            buildNumber: 7,
            minimumSystemVersion: "14.0",
            serverURL: serverURL,
            icon: icon
        )
    }

    @Test("번들과 실행 파일 이름이 새 이름으로 바뀐다")
    func renamesBundleAndExecutable() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let names = try ZipArchive.entries(in: output).map(\.name)

        #expect(names.contains("우리 스토어.app/Contents/MacOS/우리 스토어"))
        #expect(!names.contains { $0.contains("Alley Store") })
    }

    /// 실행 파일 이름은 `CFBundleExecutable` 과 같아야 한다. 어긋나면 macOS 가
    /// 번들을 열지 못한다.
    @Test("실행 파일 이름이 CFBundleExecutable 과 같다")
    func executableNameMatchesPlist() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let entries = try ZipArchive.entries(in: output)

        let plist = try #require(
            entries.first { $0.name.hasSuffix("Info.plist") }
        )
        let text = String(decoding: plist.compressedData, as: UTF8.self)
        #expect(text.contains("<key>CFBundleExecutable</key>"))
        #expect(text.contains("<string>우리 스토어</string>"))
        #expect(entries.contains { $0.name == "우리 스토어.app/Contents/MacOS/우리 스토어" })
    }

    /// 파일을 하나라도 바꾸면 임시 서명은 이미 틀린 것이다. 남겨두면 "서명이 깨진
    /// 번들" 로 보이고, 워커가 덮기 전에 무엇을 본 것인지 알 수 없게 된다.
    @Test("임시 서명을 버린다")
    func dropsAdHocSignature() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let names = try ZipArchive.entries(in: output).map(\.name)
        #expect(!names.contains { $0.contains("_CodeSignature") })
    }

    @Test("실행 파일 내용과 권한을 그대로 옮긴다")
    func copiesExecutableUntouched() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let binary = try #require(
            try ZipArchive.entries(in: output).first { $0.name.hasSuffix("MacOS/우리 스토어") }
        )
        #expect(binary.compressedData == Data("실행 파일이라고 치자".utf8))
        #expect((binary.externalAttributes >> 16) & 0o777 == 0o755)
    }

    @Test("옛 Info.plist 는 새것으로 바뀐다")
    func replacesInfoPlist() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let plists = try ZipArchive.entries(in: output).filter { $0.name.hasSuffix("Info.plist") }

        #expect(plists.count == 1)
        let text = String(decoding: plists[0].compressedData, as: UTF8.self)
        #expect(!text.contains("옛것"))
        #expect(text.contains("com.example.alley.store"))
        #expect(text.contains("<key>CFBundleVersion</key>"))
        #expect(text.contains("<string>7</string>"))
    }

    @Test("아이콘을 주면 번들에 넣고 plist 가 그것을 가리킨다")
    func addsIcon() throws {
        let png = PNGFixture.png(width: 1024, height: 1024)
        let output = try StoreAppBundleRewriter.rewrite(
            baseZip: Self.baseZip(), branding: Self.branding(icon: (png, 1024))
        )
        let entries = try ZipArchive.entries(in: output)

        let icon = try #require(entries.first { $0.name.hasSuffix("Resources/AppIcon.icns") })
        #expect(icon.compressedData.prefix(4) == Data("icns".utf8))

        let plist = try #require(entries.first { $0.name.hasSuffix("Info.plist") })
        #expect(String(decoding: plist.compressedData, as: UTF8.self).contains("CFBundleIconFile"))
    }

    /// 아이콘을 안 올렸으면 `CFBundleIconFile` 을 쓰지 않는다. 없는 파일을 가리키면
    /// macOS 가 기본 아이콘으로 떨어지는데, 그 상태는 "설정이 안 먹었다" 와 구분되지
    /// 않는다.
    @Test("아이콘이 없으면 plist 도 가리키지 않는다")
    func omitsIconKeyWithoutIcon() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let plist = try #require(
            try ZipArchive.entries(in: output).first { $0.name.hasSuffix("Info.plist") }
        )
        #expect(!String(decoding: plist.compressedData, as: UTF8.self).contains("CFBundleIconFile"))
    }

    /// 서버가 자기 주소를 안다 (ADR-0044). 운영 레포에 손으로 적을 이유가 없다.
    @Test("서버 주소를 주면 번들에 박힌다")
    func stampsServerURL() throws {
        let output = try StoreAppBundleRewriter.rewrite(
            baseZip: Self.baseZip(), branding: Self.branding(serverURL: "https://store.example.com")
        )
        let plist = try #require(
            try ZipArchive.entries(in: output).first { $0.name.hasSuffix("Info.plist") }
        )
        let text = String(decoding: plist.compressedData, as: UTF8.self)
        #expect(text.contains("<key>AlleyServerURL</key>"))
        #expect(text.contains("https://store.example.com"))
    }

    /// 앱 이름은 사람이 적는다. `&` 하나로 plist 가 깨지고, 깨진 plist 를 가진
    /// 번들은 실행되지 않는다.
    @Test("앱 이름의 특수문자가 plist 를 깨지 않는다")
    func escapesAppName() throws {
        let output = try StoreAppBundleRewriter.rewrite(
            baseZip: Self.baseZip(), branding: Self.branding(appName: "R&D <사내>")
        )
        let plist = try #require(
            try ZipArchive.entries(in: output).first { $0.name.hasSuffix("Info.plist") }
        )
        let text = String(decoding: plist.compressedData, as: UTF8.self)
        #expect(text.contains("R&amp;D &lt;사내&gt;"))
        #expect(!text.contains("R&D <사내>"))
    }

    @Test("최상위에 .app 이 없으면 무엇을 올려야 하는지 말한다")
    func rejectsZipWithoutApp() {
        let notABundle = ZipArchive.write([
            ZipArchive.stored(name: "kit/install.sh", data: Data("#!/bin/sh".utf8))
        ])
        do {
            _ = try StoreAppBundleRewriter.rewrite(baseZip: notABundle, branding: Self.branding())
            Issue.record("거절했어야 합니다.")
        } catch let abort as any AbortError {
            #expect(abort.reason.contains("`.app` 이 없습니다"))
        } catch {
            Issue.record("AbortError 가 아닙니다: \(error)")
        }
    }

    /// 같은 입력에서 같은 결과가 나와야 "무엇이 달라졌나" 를 해시로 답할 수 있다.
    @Test("같은 입력이면 바이트까지 같다")
    func isDeterministic() throws {
        let first = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let second = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        #expect(first == second)
    }
}

@Suite("아이콘 그릇")
struct ICNSWriterTests {
    @Test("icns 머리와 항목 길이가 맞는다")
    func writesHeader() throws {
        let png = PNGFixture.png(width: 1024, height: 1024)
        let icns = try ICNSWriter.icns(png: png, edge: 1024)

        #expect(icns.prefix(4) == Data("icns".utf8))
        // 전체 길이 = 머리 8 + 항목 머리 8 + PNG
        #expect(Int(bigEndian(icns, at: 4)) == icns.count)
        #expect(icns[8..<12] == Data("ic10".utf8))
        #expect(Int(bigEndian(icns, at: 12)) == 8 + png.count)
    }

    @Test("512 는 다른 자리에 들어간다")
    func usesSlotForSize() throws {
        let icns = try ICNSWriter.icns(png: PNGFixture.png(width: 512, height: 512), edge: 512)
        #expect(icns[8..<12] == Data("ic09".utf8))
    }

    /// 자리에 없는 크기를 받으면 macOS 가 늘려 그리고, 그 사실은 Dock 에 띄운 뒤에야
    /// 보인다. 올리는 자리에서 막는다.
    @Test("자리에 없는 크기는 거절한다")
    func rejectsUnsupportedSize() {
        #expect(throws: (any Error).self) {
            try ICNSWriter.icns(png: PNGFixture.png(width: 800, height: 800), edge: 800)
        }
    }

    private func bigEndian(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }
}
