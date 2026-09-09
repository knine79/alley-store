import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

/// 올라온 파일이 zip 인지 dmg 인지 내용으로 가른다.
///
/// 이름을 믿지 않는 이유는 `ArtifactFormat` 의 주석에 있다 (ADR-0032).
@Suite("아티팩트 형식 판별")
struct ArtifactFormatTests {
    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alley-format-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("zip 은 앞 4바이트로 안다")
    func detectsZip() throws {
        let url = try write([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 100))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ArtifactFormat.detect(at: url) == .zip)
    }

    /// dmg 는 앞머리가 압축 방식마다 달라서 뒤를 봐야 한다.
    @Test("dmg 는 끝 512바이트의 koly 로 안다")
    func detectsDiskImage() throws {
        var bytes = Array(repeating: UInt8(0xAB), count: 2048)
        // 마지막 512바이트가 트레일러이고 그 앞 4바이트가 `koly` 다.
        let trailerStart = bytes.count - 512
        for (offset, byte) in Array("koly".utf8).enumerated() {
            bytes[trailerStart + offset] = byte
        }
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ArtifactFormat.detect(at: url) == .diskImage)
    }

    /// `.dmg` 라고 적힌 zip 이 실제로 온다. 이름이 아니라 내용을 봐야 한다.
    @Test("확장자가 아니라 내용을 본다")
    func ignoresFileExtension() throws {
        let zip = try write([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 600))
        defer { try? FileManager.default.removeItem(at: zip) }

        let renamed = zip.deletingLastPathComponent()
            .appendingPathComponent("거짓말.dmg")
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.copyItem(at: zip, to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }

        #expect(ArtifactFormat.detect(at: renamed) == .zip)
    }

    @Test("둘 다 아니면 모른다고 한다")
    func reportsUnknown() throws {
        let url = try write(Array("이건 그냥 텍스트입니다".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ArtifactFormat.detect(at: url) == .unknown)
    }

    /// 512바이트가 안 되는 파일에서 뒤를 읽으려다 죽지 않는다.
    @Test("아주 짧은 파일에서도 죽지 않는다")
    func handlesTinyFile() throws {
        let url = try write([0x00])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ArtifactFormat.detect(at: url) == .unknown)
    }

    @Test("없는 파일이면 모른다고 한다")
    func handlesMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("없는-파일-\(UUID().uuidString)")

        #expect(ArtifactFormat.detect(at: url) == .unknown)
    }
}
