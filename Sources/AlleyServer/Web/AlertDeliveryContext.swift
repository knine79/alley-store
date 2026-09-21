import AlleyShared
import Fluent
import Vapor

/// "어디로 보내나" 한 벌이 화면에 쓰는 값 (ADR-0059).
///
/// **앱 알림과 운영 알림이 같은 것을 쓴다.** 고르는 것은 똑같고 받는 사람만 다르다.
/// 화면을 따로 만들었더니 한쪽에서 고친 것이 다른 쪽에 반영되지 않아, 같은 일을 하는
/// 화면 둘이 다르게 생겼다.
struct AlertDeliveryContext: Encodable {
    /// 지금 고른 값. `AlertDelivery` 의 rawValue.
    var target: String
    /// 사람에게 보낼 수단이 하나라도 있나. 없으면 개별 전송을 골라도 가지 않는다.
    var canReachPeople: Bool
    /// 개별 전송 선택지에 적을 이름. 받는 사람이 누구인지는 화면마다 다르다.
    var peopleName: String
    /// 그 밑에 붙일 한 줄. 몇 명에게 가는지와 어떻게 끄는지.
    var peopleNote: String
    /// 고른 값을 저장할 곳.
    var saveAction: String
    /// 채널을 새로 넣을 곳.
    var channelAction: String
    var channels: [AlertChannelRow]
    /// 채널을 넣다 틀렸을 때 그 자리에 띄울 말.
    var error: String?
}

extension Application {
    /// 사람 한 명에게 보낼 방법이 하나라도 있나.
    ///
    /// 봇 토큰이든 메일 설정이든 하나면 된다. 어느 쪽으로 갈지는 받는 사람이 정한다
    /// (`User.notifyVia`).
    var canReachPeople: Bool {
        alleyConfig.slackBotToken != nil || alleyConfig.smtp != nil
    }
}

/// 등록된 채널 한 줄.
struct AlertChannelRow: Encodable {
    var name: String
    /// 사람이 읽는 날짜. 보낸 적이 없으면 nil.
    var lastSentAt: String?
    /// 아무도 안 받고 있는데 잘 되는 줄 아는 상태를 만들지 않는다.
    var lastError: String?
    var deletePath: String
}

extension AlertDeliveryContext {
    /// 대상 행들을 화면이 쓰는 줄로 바꾼다.
    ///
    /// `deletePathPrefix` 뒤에 대상 ID 와 지우는 경로가 붙는다. 앱과 관리 화면의
    /// 경로가 달라서 부르는 쪽이 앞부분을 준다.
    static func channels(
        _ targets: [NotificationTarget],
        deletePath: (UUID) -> String
    ) -> [AlertChannelRow] {
        targets.compactMap { target in
            guard let id = try? target.requireID() else { return nil }
            return AlertChannelRow(
                name: target.name,
                // 마지막 발송에는 시각까지 붙인다. 알림이 도는지 보는 값이라 날짜만
                // 있으면 오늘 왔는지 아침에 왔는지 알 수 없다.
                lastSentAt: target.lastSentAt.map { DateStyle.minute.string(from: $0) },
                lastError: target.lastError,
                deletePath: deletePath(id)
            )
        }
    }
}
