import Foundation

/// 올라온 아티팩트가 어떤 형식인가.
///
/// 파일 이름을 믿지 않는다. 워커가 받는 파일은 오브젝트 스토리지의 키일 뿐이고,
/// 확장자는 올린 사람이 정한다. `.zip` 이라고 적힌 dmg 를 받으면 푸는 데 실패하고,
/// 그 실패는 "압축이 깨졌다" 로 보고된다. 실제로는 형식이 다른 것뿐인데 올린 사람은
/// 자기 파일이 멀쩡한 것을 알고 있어서 원인을 찾지 못한다.
///
/// 그래서 내용을 본다. 둘 다 앞뒤 몇 바이트로 확실히 갈린다.
public enum ArtifactFormat: Sendable, Equatable {
    case zip
    case diskImage
    case unknown

    /// 파일 앞뒤를 읽어 형식을 가른다.
    public static func detect(at url: URL) -> ArtifactFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        // zip 은 첫 4바이트가 로컬 헤더 시그니처다. 빈 zip 은 `PK\u{05}\u{06}` 이지만
        // 앱이 들어 있는 zip 이 비어 있을 리 없으므로 로컬 헤더만 본다.
        if let head = try? handle.read(upToCount: 4), head == Data([0x50, 0x4B, 0x03, 0x04]) {
            return .zip
        }

        // UDIF(dmg) 는 파일 **끝** 512바이트가 트레일러이고 그 앞 4바이트가 `koly` 다.
        // 앞머리는 압축 방식에 따라 달라서 앞만 봐서는 가릴 수 없다.
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int,
            size >= 512
        else {
            return .unknown
        }
        guard (try? handle.seek(toOffset: UInt64(size - 512))) != nil,
              let trailer = try? handle.read(upToCount: 4),
              trailer == Data("koly".utf8)
        else {
            return .unknown
        }
        return .diskImage
    }
}
