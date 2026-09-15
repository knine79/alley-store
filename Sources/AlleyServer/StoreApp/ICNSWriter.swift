import Foundation
import Vapor

/// PNG 한 장을 `.icns` 로 담는다.
///
/// **`.icns` 는 그림 형식이 아니라 그릇이다.** 안에 든 것은 그냥 PNG 이고, 바깥은
/// "어느 크기 자리에 무엇이 들어 있다" 를 적은 목록이다. 그래서 그림을 건드리지
/// 않고도 만들 수 있고, 리눅스 컨테이너에 이미지 라이브러리를 들일 필요가 없다.
/// 서버가 아이콘을 다룰 수 있게 된 것이 이 사실 덕이다 (ADR-0046).
///
/// **크기를 줄이지는 못한다.** 그래서 받는 크기를 자리에 딱 맞는 것으로 좁힌다.
/// 800×800 을 1024 자리에 넣으면 macOS 가 늘려 그리고, 그 사실은 Dock 에 띄운
/// 뒤에야 보인다. 512 나 1024 는 어느 디자인 도구에서나 바로 내보낼 수 있는 크기라
/// 이 제한이 사람을 막지 않는다.
///
/// 한 자리만 채운다. 1024 짜리 하나를 넣으면 macOS 가 16px 까지 알아서 줄여 그린다.
/// 자리마다 손보아 넣은 것보다 작은 크기에서 조금 무르지만, 크기별로 다른 그림을
/// 받으려면 올리는 화면이 여덟 칸이 된다.
enum ICNSWriter {
    /// `.icns` 안에서 크기마다 정해진 네 글자.
    ///
    /// 이 표에 있는 크기만 받는다. 목록을 늘리려면 그 크기의 PNG 를 만들 수 있어야
    /// 하고, 지금 서버는 줄이지 못한다.
    static let slots: [Int: String] = [
        512: "ic09",
        1024: "ic10",
    ]

    /// 받을 수 있는 한 변의 길이. 큰 것을 앞에 둬서 안내 문구가 권하는 순서로 읽힌다.
    static let acceptedEdges = slots.keys.sorted(by: >)

    enum ICNSError: Error, CustomStringConvertible {
        case unsupportedSize(Int)

        var description: String {
            switch self {
            case .unsupportedSize(let edge):
                let allowed = ICNSWriter.acceptedEdges.map { "\($0)×\($0)" }.joined(separator: " 또는 ")
                return """
                    앱 아이콘은 \(allowed) 여야 합니다. 받은 크기: \(edge)×\(edge). \
                    macOS 아이콘 형식은 정해진 크기의 자리만 있고, 서버는 그림을 \
                    줄이지 못합니다.
                    """
            }
        }
    }

    /// 정사각 PNG 한 장을 `.icns` 로 감싼다.
    ///
    /// - Parameter edge: 그 PNG 의 한 변. 호출하는 쪽이 이미 `PNGInspection` 으로
    ///   읽어둔 값을 넘긴다. 여기서 다시 읽지 않는 것은 검사와 조립을 한 자리에
    ///   섞지 않으려는 것이다.
    static func icns(png: Data, edge: Int) throws -> Data {
        guard let type = slots[edge] else {
            throw Abort(.badRequest, reason: ICNSError.unsupportedSize(edge).description)
        }

        // 항목 하나 = 종류 4바이트 + 길이 4바이트 + 내용. 길이는 그 8바이트를 포함한다.
        let entryLength = 8 + png.count
        // 파일 전체 길이도 자기 머리 8바이트를 포함한다.
        let totalLength = 8 + entryLength

        var data = Data()
        data.append(contentsOf: Array("icns".utf8))
        data.append(contentsOf: bigEndian32(UInt32(totalLength)))
        data.append(contentsOf: Array(type.utf8))
        data.append(contentsOf: bigEndian32(UInt32(entryLength)))
        data.append(png)
        return data
    }

    private static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
        ]
    }
}
