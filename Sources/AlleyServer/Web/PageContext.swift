import AlleyShared
import Vapor

/// 모든 화면이 공통으로 쓰는 껍데기 정보.
///
/// 레이아웃 템플릿이 이걸로 제목, 브랜딩, 로그인 상태를 그린다.
struct PageContext: Encodable {
    /// 브라우저 탭에 붙는 제목. 스토어 이름은 레이아웃이 뒤에 붙인다.
    var title: String?
    var store: StoreChrome
    var user: UserDTO?
    /// 껍데기에 관리 메뉴를 띄울지. 역할을 템플릿에서 비교하지 않으려고 미리 접는다.
    var isAdmin: Bool
    /// 관리자 화면 탭. 관리자 화면일 때만 채우고, 그 밖에서는 빈 배열이다.
    ///
    /// 여기 두는 이유는 이것이 껍데기 정보라서다. `isAdmin` 이 껍데기의 "관리" 링크를
    /// 접는 것과 같은 종류의 값이다. 그리고 비어 있으면 레이아웃이 탭을 아예 그리지
    /// 않으므로, 관리자 화면이 아닌 곳에 탭이 새어 나오는 일은 값을 넘기지 않는 것으로
    /// 막힌다. 화면마다 빼는 것을 기억할 필요가 없다.
    var adminTabs: [AdminTabLink]
    /// 내 설정 화면 탭. 관리자 탭과 같은 이유로 여기 둔다.
    var myTabs: [AdminTabLink]
    /// 정적 파일 주소에 붙는 지문. `AssetVersion` 참고.
    var assetVersion: String
    /// 폼을 POST 로 받아 그 자리에서 그린 화면인가.
    ///
    /// 토큰 발급은 리다이렉트하지 않는다. 토큰 원문이 그 응답에만 있어서 다음 화면에서
    /// 다시 보여줄 방법이 없기 때문이다(ADR-0013). 대신 브라우저의 주소는 POST 인 채로
    /// 남고, 새로고침하면 같은 폼이 다시 제출된다. 그렇게 생긴 토큰이 "폐기한 토큰이
    /// 다시 나타났다" 로 보인 적이 있다.
    ///
    /// 이 값이 참일 때만 `no-resubmit.js` 를 붙여 주소를 목록 주소로 바꾼다.
    var isFormResult: Bool
}

/// 화면에 바르는 브랜딩.
///
/// 관리자가 설정에서 바꾸는 값이라 그대로 HTML 에 들어간다. Leaf 가 이스케이프하지만
/// 색은 `<style>` 안에, 로고는 `src` 안에 들어가므로 이스케이프만으로는 부족하다.
/// 그래서 **저장할 때** 형식을 검사하고(`StoreSettingsValidation`), 여기서는 검사를
/// 통과한 값만 다룬다는 전제로 쓴다.
struct StoreChrome: Encodable {
    var name: String
    var logoURL: String?
    /// 브라우저 탭에 뜨는 그림. 안 올렸으면 nil 이고, 그때 레이아웃은 링크를 아예 넣지
    /// 않는다. 없는 그림을 가리키는 `<link>` 는 요청 하나를 404 로 버리기만 한다.
    var faviconURL: String?
    /// 스토어 앱의 아이콘.
    ///
    /// **지금 쓰는 곳은 `/get` 하나다.** 거기는 그 앱을 받으라고 권하는 화면이라,
    /// 스토어 로고보다 받을 앱의 그림이 맞다.
    var appIconURL: String?
    var accentColor: String?
}

extension StoreSettings {
    /// - Parameter assets: 올라와 있는 브랜딩 이미지들.
    ///
    /// **올린 로고가 설정의 로고 주소를 이긴다.** 둘 다 있을 수 있는 이유는 주소
    /// 입력이 먼저 있었기 때문이다. 올리는 쪽이 나중에 생긴 뜻이고, 무엇을 쓸지는
    /// "마지막에 한 일" 로 정하는 것이 사람이 예상하는 순서다.
    func toChrome(assets: [BrandingAssetKind: BrandingAsset]) -> StoreChrome {
        StoreChrome(
            name: storeName,
            // 올린 것 → 주소로 적은 것 → 제품 기본값 순서다. 마지막 자리가 생기면서
            // 이 둘은 이제 대개 nil 이 아니다. 그래도 옵셔널로 두는 것은 기본 그림
            // 파일이 없는 배포가 있을 수 있기 때문이다 (`DefaultBranding`).
            logoURL: assets[.logo]?.versionedPath ?? logoURL
                ?? DefaultBranding.path(for: .logo),
            faviconURL: assets[.favicon]?.versionedPath
                ?? DefaultBranding.path(for: .favicon),
            appIconURL: assets[.appIcon]?.versionedPath
                ?? DefaultBranding.path(for: .appIcon),
            accentColor: accentColor
        )
    }
}

extension Request {
    /// 로그인 여부와 무관하게 껍데기를 만든다.
    ///
    /// - Parameters:
    ///   - title: 브라우저 탭 제목. 관리자 화면은 `adminTab` 만 넘기면 탭 이름을 그대로
    ///     쓴다. 탭에 적힌 글자와 제목이 갈라지지 않게 하려는 것이다.
    ///   - adminTab: 지금 보고 있는 관리자 화면. 넘기면 탭 다섯 칸이 그려지고, 안
    ///     넘기면 그려지지 않는다.
    func pageContext(
        title: String? = nil,
        adminTab: AdminTab? = nil,
        myTab: MyTab? = nil
    ) async throws -> PageContext {
        let user = auth.get(User.self)
        return PageContext(
            title: title ?? adminTab?.title,
            store: try await storeSettings().toChrome(
                assets: try await BrandingAssetService.all(on: db)
            ),
            user: user.flatMap { try? $0.toDTO() },
            isAdmin: user?.role.canAdminister ?? false,
            adminTabs: adminTab.map(AdminTab.links(current:)) ?? [],
            myTabs: myTab.map(MyTab.links(current:)) ?? [],
            assetVersion: application.assetVersion.value,
            isFormResult: method == .POST
        )
    }
}
