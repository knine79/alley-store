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
    ///
    /// **실행 파일 이름은 번들 이름과 다르다.** `scripts/build-store-app.sh` 가
    /// `Alley Store.app` 안에 `AlleyStore` 를 담는다. 이 픽스처가 둘을 같게 두는 바람에
    /// 조립이 실행 파일을 못 찾는 것을 오래 놓쳤고, 그렇게 만들어진 앱은 서명과 공증을
    /// 통과한 뒤 받은 사람의 맥에서 열리지 않았다.
    static func baseZip(
        appName: String = "Alley Store",
        executableName: String = "AlleyStore"
    ) -> Data {
        ZipArchive.write([
            ZipArchive.stored(name: "\(appName).app/", data: Data(), mode: 0o755),
            ZipArchive.stored(
                name: "\(appName).app/Contents/MacOS/\(executableName)",
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

        // 폴더는 적은 이름, 실행 파일은 ASCII 로 바뀐 이름이다(아래 시험 참고).
        #expect(names.contains("우리 스토어.app/Contents/MacOS/AlleyStore"))
        #expect(!names.contains { $0.contains("Alley Store") })
    }

    /// **비ASCII 실행 파일 이름은 `codesign --verify --deep --strict` 가 거절한다.**
    ///
    /// `.app` 폴더 이름은 한글이어도 괜찮고 실행 파일만 그렇다. 실패는 서명이 끝난
    /// 뒤에야 `a sealed resource is missing or invalid` 한 줄로 나와서, 이름이
    /// 원인이라는 것을 짐작할 수 없다. 설치 가이드가 한글 이름을 예시로 들고 있어서
    /// 그 길을 그대로 밟는 조직이 나온다.
    ///
    /// 진짜 `codesign` 으로 확인하는 것은 `StoreAppBundleRealZipTests` 다. 여기서는
    /// 규칙만 본다.
    @Test(
        "실행 파일 이름은 ASCII 로 만든다",
        arguments: [
            // ASCII 이름은 그대로 둔다. 이미 그 이름으로 내보낸 조직의 번들 구조를
            // 이유 없이 바꾸지 않는다. 공백은 ASCII 라 문제가 없다.
            ("Alley Store", "Alley Store"),
            ("Our Store 2", "Our Store 2"),
            // 한글에서는 남는 것이 없어 제품 이름으로 떨어진다.
            ("우리 스토어", "AlleyStore"),
            ("   ", "AlleyStore"),
            // 섞여 있으면 ASCII 글자·숫자만 남긴다.
            ("한글Store", "Store"),
            ("Café Store", "CafStore"),
        ]
    )
    func derivesASCIIExecutableName(_ pair: (String, String)) {
        #expect(StoreAppBundleRewriter.executableName(for: pair.0) == pair.1)
    }

    /// 사람에게 보이는 이름은 적은 그대로여야 한다. 바꾸는 것은 실행 파일 이름뿐이다.
    @Test("보이는 이름은 그대로 두고 실행 파일만 바꾼다")
    func keepsDisplayName() throws {
        let output = try StoreAppBundleRewriter.rewrite(
            baseZip: Self.baseZip(), branding: Self.branding(appName: "우리 스토어")
        )
        let entries = try ZipArchive.entries(in: output)
        let plist = try #require(entries.first { $0.name.hasSuffix("Info.plist") })
        let text = String(decoding: plist.compressedData, as: UTF8.self)

        #expect(text.contains("<key>CFBundleDisplayName</key>"))
        #expect(text.contains("<string>우리 스토어</string>"))
        #expect(text.contains("<string>AlleyStore</string>"))
        #expect(entries.contains { $0.name.hasPrefix("우리 스토어.app/") })
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
        #expect(entries.contains { $0.name == "우리 스토어.app/Contents/MacOS/AlleyStore" })
    }

    /// 파일을 하나라도 바꾸면 임시 서명은 이미 틀린 것이다. 남겨두면 "서명이 깨진
    /// 번들" 로 보이고, 워커가 덮기 전에 무엇을 본 것인지 알 수 없게 된다.
    @Test("임시 서명을 버린다")
    func dropsAdHocSignature() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let names = try ZipArchive.entries(in: output).map(\.name)
        #expect(!names.contains { $0.contains("_CodeSignature") })
    }

    /// `ditto -c -k` 를 `--sequesterRsrc` 없이 돌리면 `._이름` 이 딸려 들어오고,
    /// `zip`(1) 은 `__MACOSX/` 를 넣는다. 그대로 옮기면 `codesign` 이
    /// `unsealed contents present in the bundle root` 로 거절한다.
    @Test("맥이 끼워 넣는 곁다리 파일을 버린다")
    func dropsAppleDoubleJunk() throws {
        let messy = ZipArchive.write([
            ZipArchive.stored(name: "Alley Store.app/", data: Data(), mode: 0o755),
            ZipArchive.stored(
                name: "Alley Store.app/Contents/MacOS/Alley Store",
                data: Data("실행 파일".utf8), mode: 0o755
            ),
            ZipArchive.stored(name: "Alley Store.app/Contents/Info.plist", data: Data("x".utf8)),
            ZipArchive.stored(
                name: "Alley Store.app/Contents/MacOS/._Alley Store", data: Data("확장 속성".utf8)
            ),
            ZipArchive.stored(name: "Alley Store.app/Contents/._MacOS", data: Data("확장 속성".utf8)),
            ZipArchive.stored(name: "__MACOSX/Alley Store.app/._Contents", data: Data("확장 속성".utf8)),
        ])

        let output = try StoreAppBundleRewriter.rewrite(baseZip: messy, branding: Self.branding())
        let names = try ZipArchive.entries(in: output).map(\.name)

        #expect(!names.contains { $0.contains("__MACOSX") })
        #expect(!names.contains { ($0.split(separator: "/").last ?? "").hasPrefix("._") })
        #expect(names.contains("우리 스토어.app/Contents/MacOS/AlleyStore"))
    }

    /// **이것이 깨진 채로 운영에 나갔다.** 서버가 실행 파일 이름을 번들 이름에서
    /// 유추해서 `Alley Store.app/Contents/MacOS/Alley Store` 를 찾았는데, 실제 번들은
    /// 그 자리에 `AlleyStore` 를 담는다. 못 찾으니 파일 이름은 그대로인 채 `Info.plist`
    /// 만 새 이름으로 바뀌었고, 받은 사람의 맥에서 "응용 프로그램이 손상되었거나
    /// 완전하지 않기 때문에 열 수 없습니다" 가 떴다. 서명도 공증도 통과한 뒤였다.
    @Test("실행 파일 이름과 plist 가 언제나 같은 것을 가리킨다", arguments: [
        ("Alley Store", "AlleyStore"),
        ("Alley Store", "Alley Store"),
        ("AlleyStore", "AlleyStore"),
    ])
    func keepsExecutableNameAndPlistInSync(_ bundle: String, _ executable: String) throws {
        let output = try StoreAppBundleRewriter.rewrite(
            baseZip: Self.baseZip(appName: bundle, executableName: executable),
            branding: Self.branding(appName: "Example Alley Store")
        )
        let entries = try ZipArchive.entries(in: output)

        let binary = try #require(
            entries.first { $0.name.contains("/Contents/MacOS/") && !$0.name.hasSuffix("/") }
        )
        let onDisk = String(binary.name.split(separator: "/").last ?? "")

        let plist = try #require(entries.first { $0.name.hasSuffix("/Contents/Info.plist") })
        let text = String(decoding: plist.compressedData, as: UTF8.self)
        let declared = try #require(
            text.components(separatedBy: "<key>CFBundleExecutable</key>").last?
                .components(separatedBy: "<string>").dropFirst().first?
                .components(separatedBy: "</string>").first
        )

        #expect(onDisk == declared)
    }

    @Test("실행 파일이 없으면 무엇이 잘못됐는지 알려준다")
    func rejectsBundleWithoutExecutable() throws {
        let empty = ZipArchive.write([
            ZipArchive.stored(name: "Alley Store.app/", data: Data(), mode: 0o755),
            ZipArchive.stored(name: "Alley Store.app/Contents/Info.plist", data: Data("x".utf8)),
        ])

        #expect(throws: (any Error).self) {
            try StoreAppBundleRewriter.rewrite(baseZip: empty, branding: Self.branding())
        }
    }

    @Test("실행 파일 내용과 권한을 그대로 옮긴다")
    func copiesExecutableUntouched() throws {
        let output = try StoreAppBundleRewriter.rewrite(baseZip: Self.baseZip(), branding: Self.branding())
        let binary = try #require(
            try ZipArchive.entries(in: output).first { $0.name.hasSuffix("MacOS/AlleyStore") }
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
