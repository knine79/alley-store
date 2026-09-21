import AlleyShared
import Foundation
import Smtp
import Vapor

/// 알림을 메일로 보낸다.
///
/// **Slack 과 다른 자리를 채운다.** Slack 은 사내 도구라 안 쓰는 사람이 있고, 계정
/// 이메일은 로그인에 이미 쓰고 있어서 누구에게나 있다. 봇 토큰을 못 받는 조직도
/// 메일 릴레이는 대개 갖고 있다.
///
/// `endpoint` 는 받는 사람의 메일 주소다. 사람에게 보낼 때는 계정 이메일이 그대로
/// 오고, 앱 대상으로 등록하면 관리자가 적은 주소가 온다.
public struct EmailChannel: NotificationChannel, Sendable {
    public let kind: NotificationChannelKind = .email

    private let application: Application
    private let config: AppConfig.SMTPConfig

    public init(application: Application, config: AppConfig.SMTPConfig) {
        self.application = application
        self.config = config
    }

    public enum ChannelError: Error, CustomStringConvertible {
        case rejected(String)

        public var description: String {
            switch self {
            case .rejected(let detail):
                return "메일 서버가 거절했습니다: \(detail)"
            }
        }
    }

    public func send(_ message: NotificationMessage, to endpoint: String) async throws {
        let email = try Email(
            from: EmailAddress(address: config.fromAddress, name: config.fromName),
            to: [EmailAddress(address: endpoint)],
            subject: message.title,
            body: body(of: message)
        )

        // 이 클라이언트는 던지는 대신 `Result` 를 돌려준다. 성공한 척 지나가지 않게
        // 여기서 갈라 우리 오류로 바꾼다.
        let result = try await application.smtp.send(email).get()
        if case .failure(let error) = result {
            throw ChannelError.rejected(String(describing: error))
        }
    }

    /// 메일 본문. **평문이다.**
    ///
    /// HTML 로 보내면 받는 쪽마다 다르게 그려지고, 우리가 넣는 것은 제목 한 줄과
    /// 본문 몇 줄과 링크 하나뿐이라 꾸밀 것이 없다. 평문은 어디서나 같게 보인다.
    private func body(of message: NotificationMessage) -> String {
        var lines = [message.title]
        if let body = message.body, !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        if let link = message.link {
            lines.append("")
            lines.append(link)
        }
        return lines.joined(separator: "\n")
    }
}

extension Application {
    /// 메일 설정을 이 애플리케이션에 심는다.
    ///
    /// 클라이언트가 `application.smtp.configuration` 한 곳을 보므로 기동할 때 한 번
    /// 넣어둔다. 설정이 없으면 아무것도 하지 않고, 그때는 메일 채널도 만들지 않는다.
    func configureSMTP(_ config: AppConfig.SMTPConfig?) {
        guard let config else { return }
        smtp.configuration = SmtpServerConfiguration(
            hostname: config.hostname,
            port: config.port,
            signInMethod: signInMethod(for: config),
            secure: secureChannel(for: config.secure),
            helloMethod: .ehlo
        )
    }

    /// 사용자 이름과 비밀번호가 둘 다 있을 때만 인증한다.
    ///
    /// 사내 릴레이는 망 안에서 오는 것을 그냥 받는 경우가 많다. 그때 빈 자격증명으로
    /// 로그인을 시도하면 오히려 거절당한다.
    private func signInMethod(for config: AppConfig.SMTPConfig) -> SignInMethod {
        guard let username = config.username, !username.isEmpty,
              let password = config.password, !password.isEmpty
        else {
            return .anonymous
        }
        return .credentials(username: username, password: password)
    }

    /// 모르는 값은 STARTTLS 로 접는다.
    ///
    /// 접는 쪽을 암호화로 두는 이유는, 오타 하나로 비밀번호가 평문으로 나가는 일을
    /// 만들지 않기 위해서다. 정말 평문으로 보내려면 `none` 이라고 적어야 한다.
    private func secureChannel(for raw: String) -> SmtpSecureChannel {
        switch raw.lowercased() {
        case "ssl", "tls": return .ssl
        case "none", "plain": return .none
        default: return .startTls
        }
    }
}
