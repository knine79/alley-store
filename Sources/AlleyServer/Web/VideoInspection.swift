import Foundation

/// MP4·MOV 파일의 머리를 읽는다 (이슈 #73, ADR-0079).
///
/// 서버는 리눅스 컨테이너라 AVFoundation 도 ffmpeg 도 없다. 그래도 형식과 길이는 알 수
/// 있다. 두 형식은 같은 뼈대(ISO 기본 미디어 파일, QuickTime 에서 갈라져 나왔다)를 쓰고,
/// 길이는 `moov` 상자 안의 `mvhd` 에 숫자 두 개로 적혀 있다.
///
/// 상자는 `[크기 4바이트][종류 4바이트][내용]` 이다. 크기가 1 이면 바로 뒤 8바이트가 진짜
/// 크기고, 0 이면 파일 끝까지다.
///
/// **코덱은 보지 않는다.** H.264 인지 HEVC 인지는 `stsd` 깊숙이 있고, 둘 다 맥에서는
/// 재생된다. 콘솔에서 HEVC 를 못 트는 브라우저가 있다는 것은 ADR 에 적었다.
enum VideoInspection {
    enum Format: Equatable {
        case mp4
        case mov

        var contentType: String {
            switch self {
            case .mp4: "video/mp4"
            case .mov: "video/quicktime"
            }
        }

        var fileExtension: String {
            switch self {
            case .mp4: "mp4"
            case .mov: "mov"
            }
        }
    }

    /// 첫 상자로 형식을 가린다. 파일 이름이나 브라우저가 붙인 형식은 믿지 않는다.
    ///
    /// `ftyp` 의 주 브랜드가 `qt  ` 면 MOV, 나머지는 MP4 다. 아주 옛날 QuickTime 은
    /// `ftyp` 없이 바로 `moov`·`mdat` 로 시작해서 그것도 MOV 로 받는다. 정말 동영상인지는
    /// 길이(`duration`)를 읽으면서 한 번 더 걸러진다.
    static func format(of data: Data) -> Format? {
        guard let first = boxes(in: data, range: data.startIndex..<data.endIndex).first
        else { return nil }
        switch first.type {
        case "ftyp":
            guard first.content.count >= 4 else { return nil }
            let brand = data[first.content.lowerBound..<(first.content.lowerBound + 4)]
            return String(decoding: brand, as: UTF8.self) == "qt  " ? .mov : .mp4
        case "moov", "mdat", "wide", "free", "skip":
            return .mov
        default:
            return nil
        }
    }

    /// 길이(초). `moov/mvhd` 가 없거나 잘못 적혔으면 nil.
    ///
    /// `moov` 는 파일 앞에도 끝에도 올 수 있다. 녹화 프로그램은 대개 끝에 둔다. 그래서
    /// 파일 전체를 받은 뒤에 본다.
    static func duration(of data: Data) -> Double? {
        let all = data.startIndex..<data.endIndex
        guard let movie = boxes(in: data, range: all).first(where: { $0.type == "moov" }),
              let header = boxes(in: data, range: movie.content).first(where: { $0.type == "mvhd" })
        else { return nil }

        let content = header.content
        guard content.count >= 4 else { return nil }
        let version = data[content.lowerBound]
        // 버전·플래그 4바이트 뒤에 만든 시각, 고친 시각, 시간 단위, 길이 순이다.
        // 버전 1 은 시각과 길이가 8바이트다.
        let timescale: UInt64
        let duration: UInt64
        if version == 1 {
            guard content.count >= 32,
                  let scale = integer(data, at: content.lowerBound + 20, size: 4),
                  let length = integer(data, at: content.lowerBound + 24, size: 8)
            else { return nil }
            timescale = scale
            duration = length
        } else {
            guard content.count >= 20,
                  let scale = integer(data, at: content.lowerBound + 12, size: 4),
                  let length = integer(data, at: content.lowerBound + 16, size: 4)
            else { return nil }
            timescale = scale
            duration = length
        }
        guard timescale > 0 else { return nil }
        return Double(duration) / Double(timescale)
    }

    /// 사람이 읽는 길이. "42초", "1분 24초".
    static func describe(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)초" }
        let rest = total % 60
        return rest == 0 ? "\(total / 60)분" : "\(total / 60)분 \(rest)초"
    }

    // MARK: - 상자

    struct Box {
        var type: String
        var content: Range<Data.Index>
    }

    /// 한 겹의 상자들. 크기가 범위를 넘거나 말이 안 되면 거기서 멈춘다.
    static func boxes(in data: Data, range: Range<Data.Index>) -> [Box] {
        var found: [Box] = []
        var offset = range.lowerBound
        while range.upperBound - offset >= 8 {
            guard let size32 = integer(data, at: offset, size: 4) else { break }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var headerSize = 8
            var size: UInt64 = size32
            if size32 == 1 {
                guard range.upperBound - offset >= 16,
                      let large = integer(data, at: offset + 8, size: 8)
                else { break }
                size = large
                headerSize = 16
            } else if size32 == 0 {
                size = UInt64(range.upperBound - offset)
            }
            guard size >= UInt64(headerSize), size <= UInt64(range.upperBound - offset) else { break }
            let end = offset + Int(size)
            found.append(Box(type: type, content: (offset + headerSize)..<end))
            offset = end
        }
        return found
    }

    /// 빅 엔디언 정수.
    private static func integer(_ data: Data, at offset: Data.Index, size: Int) -> UInt64? {
        guard offset >= data.startIndex, offset + size <= data.endIndex else { return nil }
        return data[offset..<(offset + size)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
