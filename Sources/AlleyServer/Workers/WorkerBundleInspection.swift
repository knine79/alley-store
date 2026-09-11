import AlleyShared
import Foundation
import Vapor

/// 올라온 워커 zip 이 정말 워커 번들인지 본다 (ADR-0042).
///
/// **서버는 zip 을 풀 수 없습니다.** 리눅스 컨테이너라 `ditto` 도 `codesign` 도
/// 없고, 번들의 서명은 어차피 받아가는 워커가 확인합니다. 여기서 보는 것은 zip 의
/// 목차뿐입니다.
///
/// 그래도 봐야 하는 이유는, 설치 키트(`alley-worker-kit.zip`)를 잘못 올리는 일이
/// 실제로 흔하기 때문입니다. 그것도 zip 이라 지금까지 그냥 통과했고, 잘못됐다는
/// 사실은 **10분 뒤 워커 로그에만** 남았습니다.
enum WorkerBundleInspection {
    /// zip 의 중앙 디렉터리에서 최상위 `.app` 을 찾는다.
    ///
    /// 없으면 무엇이 들었는지와 함께 사람이 읽는 이유를 돌려준다.
    static func requireTopLevelApp(in data: Data) throws {
        let names = try entryNames(in: data)
        guard !names.isEmpty else {
            throw Abort(.badRequest, reason: "빈 zip 입니다.")
        }

        // `alley-worker.app/…` 처럼 최상위가 `.app` 이어야 한다. 워커는 푼 자리의
        // 최상위에서 `.app` 을 찾으므로, 한 겹 안에 있으면 못 찾는다.
        let tops = Set(names.compactMap { $0.split(separator: "/").first.map(String.init) })
        if tops.contains(where: { $0.hasSuffix(".app") }) { return }

        // 키트를 올린 경우가 가장 흔하다. 그 사실을 알면 무엇을 올려야 하는지도 안다.
        if names.contains(where: { $0.contains(".app/") }) {
            throw Abort(
                .badRequest,
                reason: """
                    `.app` 이 한 겹 안에 있습니다. 설치 키트(alley-worker-kit.zip)를 \
                    올리신 것 같습니다. 번들만 담은 alley-worker.zip 을 올려주세요.
                    """
            )
        }
        throw Abort(
            .badRequest,
            reason: """
                zip 최상위에 `.app` 이 없습니다. \
                ./scripts/build-worker-app.sh --sign 이 만든 alley-worker.zip 을 올려주세요.
                """
        )
    }

    /// zip 중앙 디렉터리의 항목 이름들.
    ///
    /// 앞에서부터 훑지 않는다. 끝에 있는 목차만 읽으면 되는 형식이고, 워커 번들은
    /// 수십 MB 라 통째로 파싱할 이유가 없다. 브라우저 쪽 `bundle-info.js` 가 같은
    /// 일을 한다.
    static func entryNames(in data: Data) throws -> [String] {
        guard let eocd = endOfCentralDirectory(in: data) else {
            throw Abort(.badRequest, reason: "zip 의 목차를 찾지 못했습니다. 파일이 잘린 것 같습니다.")
        }

        let count = Int(read16(data, at: eocd + 10))
        let offset = Int(read32(data, at: eocd + 16))
        // 0xFFFFFFFF 는 "이 값은 zip64 확장에 있다" 는 표시다. 워커 번들이 4GB 를
        // 넘을 일은 없으니 그때는 읽기를 포기하고 통과시킨다. 여기서 막으면 멀쩡한
        // 번들을 거절할 수 있고, 진짜 검사는 워커가 한다.
        guard offset != 0xFFFF_FFFF, count != 0xFFFF, offset < data.count else { return [] }

        var names: [String] = []
        var at = data.startIndex + offset
        for _ in 0..<count {
            guard at + 46 <= data.endIndex, read32(data, at: at - data.startIndex) == 0x0201_4B50
            else {
                break
            }
            let base = at - data.startIndex
            let nameLength = Int(read16(data, at: base + 28))
            let extraLength = Int(read16(data, at: base + 30))
            let commentLength = Int(read16(data, at: base + 32))
            let nameStart = at + 46
            guard nameStart + nameLength <= data.endIndex else { break }
            if let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) {
                names.append(name)
            }
            at = nameStart + nameLength + extraLength + commentLength
        }
        return names
    }

    /// 끝에서부터 EOCD 표지를 찾는다. 주석이 최대 65535바이트라 그만큼만 본다.
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
}
