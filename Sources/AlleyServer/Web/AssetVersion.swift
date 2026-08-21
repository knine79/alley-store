import Foundation
import Vapor

/// 정적 파일 주소에 붙이는 지문.
///
/// `Cache-Control: no-cache` 는 **새로 받는** 응답에만 걸린다. 브라우저가 그 헤더가
/// 없던 시절에 이미 캐시해둔 항목은 그대로 쓴다. 그래서 헤더만으로는 "고쳤는데 반영이
/// 안 된다"를 완전히 막지 못한다.
///
/// 주소가 바뀌면 브라우저에게는 다른 파일이다. 파일이 바뀔 때 주소도 바뀌게 해서
/// 낡은 것을 쓸 방법 자체를 없앤다.
///
/// 지문은 `Public/` 안 파일들의 크기와 수정 시각으로 만든다. 내용 해시가 더 정확하지만
/// 파일을 다 읽어야 하고, 우리가 막으려는 것은 "바뀐 파일이 안 보이는 것"이라
/// 이 정도로 충분하다. 어느 파일이 바뀌어도 값이 바뀌므로 다 같이 새로 받는다.
/// 파일이 많아지면 파일별로 나누는 편이 낫다.
struct AssetVersion {
    let value: String

    /// 부팅할 때 한 번 계산한다.
    ///
    /// 요청마다 디스크를 보면 개발 중에는 편하지만 운영에서 불필요한 I/O 가 된다.
    /// 파일이 바뀌면 배포가 일어나고 배포는 프로세스를 다시 띄운다.
    init(publicDirectory: String) {
        let manager = FileManager.default
        guard let entries = try? manager.subpathsOfDirectory(atPath: publicDirectory) else {
            self.value = "0"
            return
        }

        var hasher = Hasher()
        // 파일 시스템이 주는 순서는 보장되지 않는다. 정렬해야 같은 상태에서 같은 값이 나온다.
        for path in entries.sorted() {
            let full = publicDirectory + path
            guard let attributes = try? manager.attributesOfItem(atPath: full) else { continue }
            hasher.combine(path)
            hasher.combine(attributes[.size] as? Int ?? 0)
            hasher.combine((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }

        // 부호를 떼고 36진수로 줄인다. 주소에 들어가는 값이라 짧을수록 좋다.
        self.value = String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }
}

extension Application {
    private struct AssetVersionKey: StorageKey {
        typealias Value = AssetVersion
    }

    var assetVersion: AssetVersion {
        get {
            guard let version = storage[AssetVersionKey.self] else {
                fatalError("AssetVersion 이 설정되기 전에 접근했습니다. configure(_:) 를 먼저 호출하세요.")
            }
            return version
        }
        set { storage[AssetVersionKey.self] = newValue }
    }
}
