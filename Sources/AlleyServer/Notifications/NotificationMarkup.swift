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

    /// 굵게 보일 구간으로 감싼다. 알림을 만드는 쪽이 부른다.
    public static func strong(_ text: String) -> String {
        "\(open)\(text)\(close)"
    }

    /// 평문 채널이 쓴다. 표시를 지운다.
    ///
    /// 평문에서 굵게를 흉내 내려고 별표나 대괄호를 남기지 않는다. 남기면 그것이
    /// 다시 "왜 여기에 기호가 있지" 가 된다.
    public static func plain(_ text: String) -> String {
        text.filter { $0 != open && $0 != close }
    }

    /// mrkdwn 채널(Slack)이 쓴다. `*` 하나로 감싼다.
    public static func mrkdwn(_ text: String) -> String {
        String(text.map { $0 == open || $0 == close ? "*" : $0 })
    }
}
