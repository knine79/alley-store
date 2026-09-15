import Foundation
import Vapor

/// zip 을 읽고 다시 쓴다. **압축을 풀지 않는다.**
///
/// 스토어 앱 번들에서 바꿀 것은 `Info.plist` 와 아이콘, 그리고 이름 몇 개뿐이다.
/// 나머지 - 실행 파일 수십 MB - 는 손댈 이유가 없다. 그래서 그것들은 **압축된
/// 바이트 그대로 옮긴다.** 풀었다 다시 압축하지 않으므로 리눅스 컨테이너에 zlib
/// 바인딩을 들일 필요가 없고, 큰 파일을 두 번 훑지도 않는다.
///
/// 새로 넣는 항목만 압축하지 않은 채로(`stored`) 쓴다. plist 와 아이콘은 합쳐서
/// 수백 KB 라 압축해서 얻을 것이 없다.
///
/// zip64 는 다루지 않는다. 스토어 앱 번들은 수십 MB 이고, 4GB 를 넘거나 항목이
/// 65535개를 넘으면 읽기를 포기한다. 조용히 잘못 쓰는 것보다 낫다.
enum ZipArchive {
    /// 항목 하나. 압축된 바이트를 그대로 들고 있다.
    struct Entry: Sendable {
        var name: String
        /// 0 이면 압축 없음(stored), 8 이면 deflate. 옮길 때는 값을 보지 않고 그대로 쓴다.
        var compressionMethod: UInt16
        var crc32: UInt32
        var uncompressedSize: Int
        /// 파일 권한과 종류가 상위 16비트에 들어 있다. **실행 비트가 여기 있다.**
        /// 이것을 잃으면 `.app` 안의 실행 파일이 실행되지 않는다.
        var externalAttributes: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
        /// 압축된 상태의 바이트. 원본에서 그대로 떼어온 것이다.
        var compressedData: Data

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum ZipError: Error, CustomStringConvertible {
        case notAZip
        case truncated(String)
        case unsupportedZip64

        var description: String {
            switch self {
            case .notAZip:
                return "zip 이 아닙니다."
            case .truncated(let detail):
                return "zip 이 잘렸거나 깨졌습니다: \(detail)"
            case .unsupportedZip64:
                return """
                    zip64 형식입니다. 스토어 앱 번들이 4GB 를 넘거나 항목이 65535개를 \
                    넘는다는 뜻이라, 올린 파일이 스토어 앱 번들이 맞는지 확인해주세요.
                    """
            }
        }
    }

    // MARK: - 읽기

    /// 목차를 읽어 항목 전부를 꺼낸다.
    ///
    /// 목차(central directory)만 믿고 각 항목의 로컬 헤더로 찾아간다. 앞에서부터
    /// 훑지 않는 이유는 형식이 그렇게 쓰라고 만들어졌기 때문이다. 목차에는 크기와
    /// CRC 가 반드시 들어 있지만 로컬 헤더에는 없을 수 있다(아래 참고).
    static func entries(in data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAZip }
        guard let eocd = endOfCentralDirectory(in: data) else { throw ZipError.notAZip }

        let count = Int(read16(data, at: eocd + 10))
        let directoryOffset = Int(read32(data, at: eocd + 16))
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ZipError.unsupportedZip64
        }
        guard directoryOffset < data.count else {
            throw ZipError.truncated("목차 위치가 파일 밖을 가리킵니다.")
        }

        var entries: [Entry] = []
        var cursor = directoryOffset

        for index in 0..<count {
            guard cursor + 46 <= data.count else {
                throw ZipError.truncated("\(index + 1)번째 목차 항목이 모자랍니다.")
            }
            guard read32(data, at: cursor) == 0x0201_4B50 else {
                throw ZipError.truncated("\(index + 1)번째 목차 항목의 표지가 틀립니다.")
            }

            let flags = read16(data, at: cursor + 8)
            let method = read16(data, at: cursor + 10)
            let dosTime = read16(data, at: cursor + 12)
            let dosDate = read16(data, at: cursor + 14)
            let crc = read32(data, at: cursor + 16)
            let compressedSize = Int(read32(data, at: cursor + 20))
            let uncompressedSize = Int(read32(data, at: cursor + 24))
            let nameLength = Int(read16(data, at: cursor + 28))
            let extraLength = Int(read16(data, at: cursor + 30))
            let commentLength = Int(read16(data, at: cursor + 32))
            let externalAttributes = read32(data, at: cursor + 38)
            let localOffset = Int(read32(data, at: cursor + 42))

            guard compressedSize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ZipError.unsupportedZip64
            }
            guard cursor + 46 + nameLength <= data.count else {
                throw ZipError.truncated("항목 이름이 파일 밖으로 나갑니다.")
            }

            let nameBytes = data[(data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength)]
            // 이름이 UTF-8 이 아닐 수 있다. 그때는 이 zip 을 다룰 수 없다고 보는 편이
            // 낫다. 깨진 이름으로 `.app` 안의 경로를 맞출 수는 없다.
            guard let name = String(data: nameBytes, encoding: .utf8) else {
                throw ZipError.truncated("항목 이름을 UTF-8 로 읽지 못했습니다.")
            }

            // 로컬 헤더의 이름·추가 필드 길이는 목차의 것과 다를 수 있다. 데이터가
            // 어디서 시작하는지는 로컬 헤더를 직접 읽어야만 알 수 있다.
            guard localOffset + 30 <= data.count,
                  read32(data, at: localOffset) == 0x0403_4B50
            else {
                throw ZipError.truncated("'\(name)' 의 로컬 헤더를 찾지 못했습니다.")
            }
            let localNameLength = Int(read16(data, at: localOffset + 26))
            let localExtraLength = Int(read16(data, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength

            guard dataStart + compressedSize <= data.count else {
                throw ZipError.truncated("'\(name)' 의 내용이 모자랍니다.")
            }

            entries.append(
                Entry(
                    name: name,
                    compressionMethod: method,
                    crc32: crc,
                    uncompressedSize: uncompressedSize,
                    externalAttributes: externalAttributes,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    compressedData: Data(
                        data[(data.startIndex + dataStart)..<(data.startIndex + dataStart + compressedSize)]
                    )
                )
            )

            // 데이터 서술자(플래그 3번 비트)를 쓰는 항목은 로컬 헤더의 크기가 0 이고
            // 진짜 값이 데이터 뒤에 붙는다. 우리는 목차의 값을 이미 읽었고, 다시 쓸
            // 때 그 값을 로컬 헤더에 박아 서술자 자체를 없앤다. 그래서 여기서는
            // 서술자 바이트를 건너뛰기만 하면 되고, 그것은 다음 항목의 로컬 헤더
            // 위치가 목차에 적혀 있으므로 저절로 된다.
            _ = flags

            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    // MARK: - 쓰기

    /// 압축하지 않은 항목 하나를 만든다. 새로 넣는 파일이 이 길로 온다.
    ///
    /// - Parameter mode: 유닉스 권한. 실행 파일은 0o755, 보통 파일은 0o644.
    static func stored(name: String, data: Data, mode: UInt16 = 0o644) -> Entry {
        Entry(
            name: name,
            compressionMethod: 0,
            crc32: CRC32.checksum(data),
            uncompressedSize: data.count,
            // 상위 16비트가 유닉스 권한이다. 정규 파일을 뜻하는 0o100000 을 함께 넣는다.
            // 이것이 없으면 푸는 쪽이 권한을 0 으로 보고 읽을 수 없는 파일을 만든다.
            externalAttributes: UInt32(mode | 0o100000) << 16,
            dosTime: 0,
            dosDate: Self.dosEpochDate,
            compressedData: data
        )
    }

    /// 항목들을 모아 zip 한 장으로 만든다.
    static func write(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let localOffset = output.count

            output.append(contentsOf: le32(0x0403_4B50))
            output.append(contentsOf: le16(20))  // 풀려면 2.0 이상이면 된다
            // 11번 비트: 이름이 UTF-8 이다. 앱 이름에 한글이 들어갈 수 있어서 늘 켠다.
            // 3번 비트(데이터 서술자)는 끈다. 크기와 CRC 를 여기 바로 적기 때문이다.
            output.append(contentsOf: le16(1 << 11))
            output.append(contentsOf: le16(entry.compressionMethod))
            output.append(contentsOf: le16(entry.dosTime))
            output.append(contentsOf: le16(entry.dosDate))
            output.append(contentsOf: le32(entry.crc32))
            output.append(contentsOf: le32(UInt32(entry.compressedData.count)))
            output.append(contentsOf: le32(UInt32(entry.uncompressedSize)))
            output.append(contentsOf: le16(UInt16(nameBytes.count)))
            output.append(contentsOf: le16(0))  // 추가 필드는 옮기지 않는다
            output.append(nameBytes)
            output.append(entry.compressedData)

            directory.append(contentsOf: le32(0x0201_4B50))
            directory.append(contentsOf: le16(0x031E))  // 유닉스에서 만들었다, 3.0
            directory.append(contentsOf: le16(20))
            directory.append(contentsOf: le16(1 << 11))
            directory.append(contentsOf: le16(entry.compressionMethod))
            directory.append(contentsOf: le16(entry.dosTime))
            directory.append(contentsOf: le16(entry.dosDate))
            directory.append(contentsOf: le32(entry.crc32))
            directory.append(contentsOf: le32(UInt32(entry.compressedData.count)))
            directory.append(contentsOf: le32(UInt32(entry.uncompressedSize)))
            directory.append(contentsOf: le16(UInt16(nameBytes.count)))
            directory.append(contentsOf: le16(0))  // 추가 필드
            directory.append(contentsOf: le16(0))  // 주석
            directory.append(contentsOf: le16(0))  // 디스크 번호
            directory.append(contentsOf: le16(0))  // 내부 속성
            directory.append(contentsOf: le32(entry.externalAttributes))
            directory.append(contentsOf: le32(UInt32(localOffset)))
            directory.append(nameBytes)
        }

        let directoryOffset = output.count
        output.append(directory)

        output.append(contentsOf: le32(0x0605_4B50))
        output.append(contentsOf: le16(0))  // 이 디스크 번호
        output.append(contentsOf: le16(0))  // 목차가 시작하는 디스크
        output.append(contentsOf: le16(UInt16(entries.count)))
        output.append(contentsOf: le16(UInt16(entries.count)))
        output.append(contentsOf: le32(UInt32(directory.count)))
        output.append(contentsOf: le32(UInt32(directoryOffset)))
        output.append(contentsOf: le16(0))  // 주석 길이
        return output
    }

    /// MS-DOS 날짜로 1980-01-01. 0 은 유효한 날짜가 아니라 푸는 도구가 경고를 낸다.
    ///
    /// 실제 시각을 쓰지 않는 이유는 **같은 입력에서 같은 zip 이 나오게** 하려는
    /// 것이다. 빌드를 두 번 돌렸을 때 결과가 바이트까지 같으면 "무엇이 달라졌나" 를
    /// 해시로 답할 수 있다.
    static let dosEpochDate: UInt16 = (0 << 9) | (1 << 5) | 1

    // MARK: - 바이트 읽기

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        let window = min(data.count, 65535 + 22)
        guard window >= 22 else { return nil }
        var index = data.count - 22
        let floor = data.count - window
        while index >= floor {
            if read32(data, at: index) == 0x0605_4B50 { return index }
            index -= 1
        }
        return nil
    }

    private static func read16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        guard base + 2 <= data.endIndex else { return 0 }
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return 0 }
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF),
            UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF),
        ]
    }
}

// MARK: - CRC32

/// zip 이 요구하는 검사합.
///
/// 옮기는 항목은 원본의 값을 그대로 쓰므로 계산할 일이 없다. 새로 넣는 `Info.plist`
/// 와 아이콘만 여기를 지난다.
enum CRC32 {
    /// 표준 다항식 0xEDB88320 의 표. 처음 쓸 때 한 번 만든다.
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
