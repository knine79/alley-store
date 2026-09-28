import Testing

@testable import AlleyServer

/// 강조를 채널마다 제 문법으로 옮긴다.
///
/// 본문에 마크다운 `**굵게**` 를 그대로 적었다가, 메일에서는 별표가 글자로 보이고
/// Slack 에서는 아무것도 되지 않는 것을 겪었다. 여기서 보는 것은 "본문을 만드는
/// 쪽이 문법을 모르고, 채널이 저마다 옮긴다" 는 것이다.
@Suite("알림 강조")
struct NotificationMarkupTests {
    @Test("평문 채널에는 표시가 남지 않는다")
    func plainDropsTheMarkers() {
        let body = "앞 \(NotificationMarkup.strong("가운데")) 뒤"

        #expect(NotificationMarkup.plain(body) == "앞 가운데 뒤")
    }

    @Test("mrkdwn 채널에는 별표 하나로 간다")
    func mrkdwnUsesASingleStar() {
        let body = "앞 \(NotificationMarkup.strong("가운데")) 뒤"

        #expect(NotificationMarkup.mrkdwn(body) == "앞 *가운데* 뒤")
    }

    /// 강조를 쓰지 않는 알림이 대부분이다. 그것들이 지나가면서 달라지면 안 된다.
    @Test("강조가 없는 글은 양쪽 다 그대로 둔다")
    func textWithoutEmphasisIsUntouched() {
        let body = "서명이 실패했습니다. 인증서가 만료됐습니다."

        #expect(NotificationMarkup.plain(body) == body)
        #expect(NotificationMarkup.mrkdwn(body) == body)
    }

    /// 마크다운을 쓰던 자리를 되돌리지 못하게 막는다. 별표가 글자로 나가면
    /// 받는 쪽 화면에 그대로 보인다.
    @Test("어느 채널로 가도 마크다운 별표가 남지 않는다")
    func neitherChannelLeavesMarkdownStars() {
        let body = "앞 \(NotificationMarkup.strong("가운데")) 뒤"

        #expect(!NotificationMarkup.plain(body).contains("*"))
        #expect(!NotificationMarkup.mrkdwn(body).contains("**"))
    }

    @Test("강조가 여러 번 나와도 짝이 맞는다")
    func severalEmphasesStayPaired() {
        let body = "\(NotificationMarkup.strong("하나")) 와 \(NotificationMarkup.strong("둘"))"

        #expect(NotificationMarkup.mrkdwn(body) == "*하나* 와 *둘*")
        #expect(NotificationMarkup.plain(body) == "하나 와 둘")
    }

    /// 실제로 나가는 알림 한 건을 끝까지 본다. 강조를 쓰는 곳이 여기뿐이라,
    /// 이 자리가 무너지면 마크다운으로 되돌아간 것이다.
    @Test("소유자를 정해야 하는 앱 알림이 두 채널 모두에서 깨끗하다")
    func theOrphanNoticeIsCleanOnBothChannels() {
        let body = """
            \(NotificationMarkup.strong("소유자를 정해야 하는 앱 1개")): 타이머. \
            함께 맡던 사람이 없어 넘기지 못했습니다.
            """

        let mail = NotificationMarkup.plain(body)
        #expect(mail.hasPrefix("소유자를 정해야 하는 앱 1개: 타이머."))
        #expect(!mail.contains("*"))

        let slack = NotificationMarkup.mrkdwn(body)
        #expect(slack.hasPrefix("*소유자를 정해야 하는 앱 1개*: 타이머."))
        #expect(!slack.contains("**"))
    }
}
