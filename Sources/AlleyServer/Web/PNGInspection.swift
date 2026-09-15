import Foundation
import Vapor

/// 올라온 PNG 의 머리 부분만 읽는다.
///
/// **왜 PNG 만 받는가.** 스토어 앱 아이콘은 `.icns` 로 번들에 들어가는데, 그 형식은
/// PNG 를 그대로 담는 그릇이다(ADR-0046). 다른 형식을 받으면 서버가 그것을 PNG 로
/// 바꿔야 하고, 리눅스 컨테이너에는 그 일을 할 이미지 라이브러리가 없다. 받는 형식을
/// 좁히는 것이 변환기를 들이는 것보다 낫다.
///
/// **왜 여기서 크기를 보는가.** 너무 작은 그림을 받으면 아이콘이 흐리게 나가는데,
/// 그 사실은 앱을 서명·공증까지 마치고 Dock 에 띄운 뒤에야 드러난다. 그때는 되돌리는
/// 데 공증 대기만큼이 더 든다. 올리는 자리에서 막는다.
///
/// 픽셀은 건드리지 않는다. 머리 24바이트만 읽으므로 이미지 라이브러리가 필요 없다.
enum PNGInspection {
    /// PNG 파일 시그니처. 이 여덟 바이트로 시작하지 않으면 PNG 가 아니다.
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    struct Size: Equatable, Sendable {
        var width: Int
        var height: Int

        var isSquare: Bool { width == height }
    }

    /// 머리에서 가로·세로를 읽는다.
    ///
    /// PNG 는 시그니처 뒤 첫 청크가 반드시 `IHDR` 이고 그 안에 크기가 있다. 규격이
    /// 그렇게 정해 두어서 앞 24바이트만 보면 된다.
    static func size(of data: Data) throws -> Size {
        guard data.count >= 24 else {
            throw Abort(.badRequest, reason: "PNG 로 읽기에 너무 짧은 파일입니다.")
        }
        guard data.prefix(8).elementsEqual(signature) else {
            throw Abort(.badRequest, reason: "PNG 파일이 아닙니다. 확장자만 바꾼 파일일 수 있습니다.")
        }

        let base = data.startIndex
        // 8: 시그니처 뒤. 그 자리에 청크 길이(4) 가 있고, 12 부터 청크 종류 네 글자다.
        guard data[(base + 12)..<(base + 16)].elementsEqual(Array("IHDR".utf8)) else {
            throw Abort(.badRequest, reason: "PNG 의 머리(IHDR)를 찾지 못했습니다. 파일이 깨진 것 같습니다.")
        }

        return Size(
            width: Int(bigEndian32(data, at: 16)),
            height: Int(bigEndian32(data, at: 20))
        )
    }

    /// 크기 조건까지 함께 본다.
    ///
    /// - Parameters:
    ///   - rule: 그 자리가 요구하는 크기.
    ///   - label: 실패 문구에 쓸 이름. "파비콘", "앱 아이콘" 처럼 화면의 말과 같아야
    ///     사람이 어느 칸이 틀렸는지 안다.
    static func validate(_ data: Data, rule: BrandingSizeRule, label: String) throws -> Size {
        let size = try self.size(of: data)

        guard size.isSquare else {
            throw Abort(
                .badRequest,
                reason: """
                    \(label)은 정사각형이어야 합니다. 받은 크기: \(size.width)×\(size.height). \
                    정사각형이 아니면 macOS 와 브라우저가 제각기 다르게 잘라냅니다.
                    """
            )
        }

        switch rule {
        case .atLeast(let minimum):
            guard size.width >= minimum else {
                throw Abort(
                    .badRequest,
                    reason: "\(label)은 \(minimum)×\(minimum) 이상이어야 합니다. 받은 크기: \(size.width)×\(size.width)."
                )
            }
        case .exactly(let allowed):
            guard allowed.contains(size.width) else {
                let list = allowed.sorted(by: >).map { "\($0)×\($0)" }.joined(separator: " 또는 ")
                throw Abort(
                    .badRequest,
                    reason: """
                        \(label)은 \(list) 여야 합니다. 받은 크기: \(size.width)×\(size.width). \
                        macOS 아이콘 형식에는 정해진 크기의 자리만 있고, 서버는 그림을 \
                        줄이지 못합니다.
                        """
                )
            }
        }
        return size
    }
}

/// 자리마다 다른 크기 요구.
///
/// 파비콘과 로고는 브라우저가 알아서 줄여 그리니 하한만 있으면 된다. 앱 아이콘은
/// `.icns` 의 정해진 자리에 들어가야 해서 크기가 딱 맞아야 한다(`ICNSWriter`).
public enum BrandingSizeRule: Sendable {
    case atLeast(Int)
    case exactly([Int])

    /// 화면에 적는 요구 사항 한 줄.
    public var requirement: String {
        switch self {
        case .atLeast(let minimum):
            "\(minimum)×\(minimum) 이상"
        case .exactly(let allowed):
            allowed.sorted(by: >).map { "\($0)×\($0)" }.joined(separator: " 또는 ")
        }
    }
}

extension PNGInspection {
    fileprivate static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }
}
