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
    /// 정적 파일 주소에 붙는 지문. `AssetVersion` 참고.
    var assetVersion: String
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
    var accentColor: String?
}

extension StoreSettings {
    func toChrome() -> StoreChrome {
        StoreChrome(name: storeName, logoURL: logoURL, accentColor: accentColor)
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
        adminTab: AdminTab? = nil
    ) async throws -> PageContext {
        let user = auth.get(User.self)
        return PageContext(
            title: title ?? adminTab?.title,
            store: try await storeSettings().toChrome(),
            user: user.flatMap { try? $0.toDTO() },
            isAdmin: user?.role.canAdminister ?? false,
            adminTabs: adminTab.map(AdminTab.links(current:)) ?? [],
            assetVersion: application.assetVersion.value
        )
    }
}
