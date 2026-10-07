import Foundation

/// 본문에서 굵게 보일 곳을 채널마다 제 문법으로 옮긴다.
///
/// **문법을 글자로 박지 않는다.** 처음에는 본문에 마크다운 `**굵게**` 를 그대로
/// 적었다. 마크다운은 우리가 내보내는 어느 채널의 문법도 아니다. 메일은 평문이라
/// 별표가 그대로 보였고, Slack 은 mrkdwn 이라 굵게가 `*하나*` 여서 아무것도 되지
/// 않았다. 가장 중요한 줄이 강조는커녕 지저분하게 나갔다.
///
/// 그래서 본문에는 자리만 표시해두고, 보내기 직전에 채널이 자기 문법으로 바꾼다.
/// 표시에는 제어 문자를 쓴다. 사람이 적는 글에 섞일 일이 없어서, 강조를 쓰지 않는
/// 본문은 그냥 지나간다.
public enum NotificationMarkup {
    /// 강조가 시작되는 자리 (STX).
    private static let open: Character = "\u{2}"
    /// 강조가 끝나는 자리 (ETX).
    private static let close: Character = "\u{3}"
    /// 링크가 시작되는 자리 (SOH). 뒤에 주소, 가름표, 글이 온다.
    private static let linkOpen: Character = "\u{1}"
    /// 링크의 주소와 글을 가르는 자리 (US).
    private static let linkSeparator: Character = "\u{1F}"
    /// 링크가 끝나는 자리 (EOT).
    private static let linkClose: Character = "\u{4}"

    /// 굵게 보일 구간으로 감싼다. 알림을 만드는 쪽이 부른다.
    public static func strong(_ text: String) -> String {
        "\(open)\(text)\(close)"
    }

    /// 글에 주소를 건다 (ADR-0076). Slack 은 글만 보이고 누르면 간다. 메일은 글 뒤에
    /// 주소를 붙인다. 주간 소식처럼 링크가 여럿인 본문이 쓴다.
    public static func link(_ url: String, _ text: String) -> String {
        "\(linkOpen)\(url)\(linkSeparator)\(text)\(linkClose)"
    }

    /// 평문 채널이 쓴다. 표시를 지운다.
    ///
    /// 평문에서 굵게를 흉내 내려고 별표나 대괄호를 남기지 않는다. 남기면 그것이
    /// 다시 "왜 여기에 기호가 있지" 가 된다. 링크는 `글 (주소)` 로 푼다.
    public static func plain(_ text: String) -> String {
        renderLinks(text) { url, label in "\(label) (\(url))" }
            .filter { $0 != open && $0 != close }
    }

    /// mrkdwn 채널(Slack)이 쓴다. `*` 하나로 감싼다. 링크는 `<주소|글>` 이다.
    ///
    /// **사람이 쓴 글의 `& < >` 를 바꾼다.** Slack 은 `<...>` 를 링크로 읽는다. 앱 소개에
    /// `<https://evil.example.com|콘솔에서 확인>` 이라고 써 두면 관리자 DM 에 진짜처럼
    /// 보이는 링크가 생긴다. 우리가 거는 링크는 표시로 따로 오므로 바꾼 뒤에 만든다.
    public static func mrkdwn(_ text: String) -> String {
        let linked = renderLinks(escapedForSlack(text)) { url, label in "<\(url)|\(label)>" }
        return String(linked.map { $0 == open || $0 == close ? "*" : $0 })
    }

    /// 사람이 쓴 글을 본문에 넣을 때 감싼다. 표시 문자를 지운다.
    ///
    /// 앱 소개에 표시 문자를 넣어 두면 `& < >` 를 바꿔도 우리 링크 표시로 읽혀 진짜
    /// 링크가 만들어진다. 이름, 소개, 버전처럼 사람이 쓴 것은 모두 이것을 지난다.
    public static func literal(_ text: String) -> String {
        text.filter { !markers.contains($0) }
    }

    private static let markers: Set<Character> = [open, close, linkOpen, linkSeparator, linkClose]

    /// Slack 이 뜻으로 읽는 세 글자를 바꾼다. 표시 문자는 건드리지 않는다.
    ///
    /// 제목처럼 본문 밖에서 Slack 에 그대로 실리는 글도 이것을 지난다.
    public static func escapedForSlack(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 링크 표시를 채널의 문법으로 바꾼다. 닫히지 않은 표시는 글만 남긴다.
    private static func renderLinks(
        _ text: String,
        _ render: (_ url: String, _ label: String) -> String
    ) -> String {
        guard text.contains(linkOpen) else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: linkOpen) {
            result += rest[..<start]
            let body = rest[rest.index(after: start)...]
            guard let end = body.firstIndex(of: linkClose) else {
                result += body.filter { $0 != linkSeparator }
                return result
            }
            let inner = body[..<end]
            if let split = inner.firstIndex(of: linkSeparator) {
                result += render(String(inner[..<split]), String(inner[inner.index(after: split)...]))
            } else {
                result += inner
            }
            rest = body[body.index(after: end)...]
        }
        return result + rest
    }
}
