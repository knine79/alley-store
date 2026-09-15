import Foundation
import NIOConcurrencyHelpers
import Vapor

/// 아무것도 안 올렸을 때 쓰는 기본 그림.
///
/// **새로 세운 스토어가 빈 화면으로 시작하지 않게 한다.** 예전에는 파비콘도 로고도
/// 앱 아이콘도 없는 채로 떠서, 탭에는 아무것도 없고 머리에는 글자만 있고 스토어 앱은
/// 기본 아이콘을 달고 나왔다. 그것을 채우려면 관리자가 그림 셋을 만들어 올려야 했는데,
/// 세우자마자 해야 하는 일 치고는 무겁다.
///
/// 조직 고유값이 아니다 (ADR-0003). 가게 차양과 문을 그린 일반적인 그림이라 어느
/// 조직이 써도 어색하지 않고, 자기 그림을 올리면 그것이 이긴다.
///
/// 파일은 `Resources/DefaultBranding/` 에 있고 Leaf 템플릿과 같은 방식으로 실행
/// 디렉터리에서 읽는다. SPM 리소스로 넣지 않는 이유는 서버가 이미 `Public` 과
/// `Resources/Views` 를 그렇게 읽고 있어서, 여기만 다른 방식을 쓰면 배포 이미지에
/// 무엇을 넣어야 하는지가 두 갈래가 되기 때문이다.
enum DefaultBranding {
    /// 파일이 놓이는 자리. 실행 디렉터리 기준이다.
    static let directoryName = "Resources/DefaultBranding"

    /// 한 번 읽으면 들고 있는다. 파비콘은 화면마다 불린다.
    private static let cache = NIOLockedValueBox<[BrandingAssetKind: Data]>([:])

    /// 이 종류의 기본 그림. 파일이 없으면 nil 이고, 그때는 예전처럼 아무것도 없다.
    static func data(for kind: BrandingAssetKind, in directory: DirectoryConfiguration) -> Data? {
        if let cached = cache.withLockedValue({ $0[kind] }) { return cached }

        let path = directory.workingDirectory + directoryName + "/" + fileName(for: kind)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        cache.withLockedValue { $0[kind] = data }
        return data
    }

    /// `app-icon` 대신 `appIcon.png` 를 쓴다. 파일 이름은 사람이 폴더에서 보는
    /// 것이라 케이스에 맞춘 이름이 읽기 낫고, 주소로 쓰이지도 않는다.
    static func fileName(for kind: BrandingAssetKind) -> String {
        switch kind {
        case .favicon: "favicon.png"
        case .logo: "logo.png"
        case .appIcon: "appIcon.png"
        }
    }

    /// 기본 그림을 가리키는 주소.
    ///
    /// 올린 그림과 달리 내용이 바뀌지 않으므로 `?v=` 가 붙지 않는다. 판이 바뀌는 것은
    /// 제품을 새로 배포할 때뿐이고, 그때는 ETag 가 달라진다.
    static func path(for kind: BrandingAssetKind) -> String {
        "/branding/\(kind.rawValue).png"
    }
}
