import Foundation
import Vapor

/// 설정값 중 화면에 그대로 박히는 것들의 형식 검사.
///
/// 강조색은 `<style>` 안에, 로고 주소는 `src` 안에 들어간다. Leaf 의 HTML
/// 이스케이프는 태그를 깨는 것만 막고, `--accent: red; } body { display: none }`
/// 같은 CSS 주입이나 `javascript:` 스킴은 막지 못한다.
///
/// 설정을 바꿀 수 있는 사람은 관리자뿐이고 관리자는 이미 서버를 통제하므로 이것을
/// "공격 방어"라고 부르기는 어렵다. 그보다는 **오타로 화면을 통째로 깨뜨리는 일을
/// 저장 시점에 걸러내는 것**에 가깝다. 색을 잘못 넣고 나서 콘솔이 하얗게 나오면
/// 되돌릴 화면조차 안 보인다.
enum StoreSettingsValidation {
    /// `#RGB`, `#RRGGBB`, `#RRGGBBAA` 만 허용한다.
    static func validatedAccentColor(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed

        guard [3, 6, 8].contains(hex.count),
              hex.allSatisfy({ $0.isHexDigit && $0.isASCII })
        else {
            throw Abort(.badRequest, reason: "강조색은 #RGB, #RRGGBB, #RRGGBBAA 형식이어야 합니다.")
        }
        return "#" + hex.lowercased()
    }

    /// `http` 와 `https` 만 허용한다.
    ///
    /// `javascript:` 는 요즘 브라우저가 `img src` 에서 실행하지 않지만, 이 값이
    /// 나중에 다른 자리에 쓰일 수 있다. 스킴을 좁혀두는 편이 안전하다.
    static func validatedLogoURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil
        else {
            throw Abort(.badRequest, reason: "로고 주소는 http 또는 https 로 시작하는 절대 주소여야 합니다.")
        }
        return trimmed
    }
}
