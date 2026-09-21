import AlleyShared
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// 서버 이미지에 함께 들어 있는 베이스 번들 (ADR-0048).
///
/// **스토어를 세우자마자 스토어 앱을 내보낼 수 있어야 한다.** 예전에는 제품 릴리스에서
/// `alley-store-app-unsigned.zip` 을 받아 관리 화면에 올려야 빌드 버튼이 켜졌다. 그
/// 한 단계가 새 조직마다 걸렸고, 제품을 올릴 때마다 다시 걸렸다. 잊으면 옛 코드로
/// 계속 빌드되는데 화면은 아무 말도 하지 않는다.
///
/// 서버는 macOS 바이너리를 **컴파일** 하지 못한다. 리눅스 컨테이너이고 `codesign` 도
/// 없다. 그래서 컴파일은 여전히 CI 의 macOS 잡이 하고, 그 결과물을 같은 릴리스의
/// 서버 이미지 안에 넣어 둔다. 서버가 하는 일은 그대로 조립뿐이다 (ADR-0046).
///
/// 이렇게 두면 **서버 버전과 스토어 앱 제품 버전이 어긋날 수 없다.** 둘이 같은
/// 커밋에서 나오기 때문이다. 버전을 사람이 적던 칸이 사라진다.
enum BundledStoreApp {
    /// 이미지 안에서 번들이 놓이는 자리. 실행 디렉터리 기준이다.
    static let path = "Resources/StoreAppBundle/alley-store-app-unsigned.zip"

    /// 한 번 읽으면 들고 있는다. 500KB 남짓이고 빌드할 때마다 읽힌다.
    private static let cache = NIOLockedValueBox<Data??>(nil)

    /// 이 자리를 찾을 밑동. **시험에서만 바꾼다.**
    ///
    /// 바꿀 수 있게 둔 이유가 있다. 예전에는 시험이 레포의 실제 디렉터리에 번들을
    /// 써 넣고 지웠다. 그러면 **그 자리에 파일을 두고 개발할 수 없다.** 운영과 같은
    /// 화면을 보려고 넣어두면 "이미지에 번들이 없을 때" 를 보는 시험 넷이 깨지고,
    /// CI 는 그 자리가 늘 비어 있어서 아무도 모른다.
    private static let rootOverride = NIOLockedValueBox<String?>(nil)

    /// 이미지에 들어 있는 번들. 없으면 nil 이다.
    ///
    /// 없을 수 있는 이유는 두 가지다. 로컬에서 `docker build` 를 그냥 돌렸거나,
    /// macOS 잡이 실패한 릴리스다. 그때는 예전처럼 사람이 올리는 길로 굴러간다.
    static func data(in directory: DirectoryConfiguration) -> Data? {
        if let cached = cache.withLockedValue({ $0 }) { return cached }

        let root = rootOverride.withLockedValue { $0 } ?? directory.workingDirectory
        let data = FileManager.default.contents(atPath: root + path)
        cache.withLockedValue { $0 = .some(data) }
        return data
    }

    /// 번들을 찾을 자리를 갈아끼운다. **시험에서만 쓴다.**
    ///
    /// nil 을 주면 원래대로 실행 디렉터리를 본다. 자리를 바꾸면 들고 있던 것도
    /// 함께 버린다. 안 버리면 앞 시험이 읽어둔 것이 그대로 나온다.
    static func useRootForTesting(_ root: String?) {
        rootOverride.withLockedValue { $0 = root }
        forgetCacheForTesting()
    }

    /// 지금 가리키고 있는 자리. **시험에서만 쓴다.** 그 자리에 파일을 놓으려면
    /// 어디인지 알아야 한다.
    static var rootForTesting: String {
        rootOverride.withLockedValue { $0 } ?? ""
    }

    /// 들고 있던 것을 버린다. **시험에서만 쓴다.**
    ///
    /// 파일은 배포된 뒤 바뀌지 않으므로 운영에서는 버릴 이유가 없다. 시험은 있을
    /// 때와 없을 때를 모두 돌려야 해서 그 사이에 한 번 비워야 한다.
    static func forgetCacheForTesting() {
        cache.withLockedValue { $0 = nil }
    }

    /// 그 번들이 담고 있는 제품 버전.
    ///
    /// 파일에서 읽지 않는다. 같은 커밋에서 나온 것이므로 서버 버전이 곧 그 값이다.
    /// 파일 안의 `Info.plist` 를 다시 읽으면 두 곳에서 관리하는 값이 되고, 어긋났을
    /// 때 어느 쪽이 참인지 알 방법이 없다.
    static var version: String { AlleyVersion.current }
}
