import Foundation

/// 앱 스크린샷의 상한 (이슈 #40).
///
/// 지키는 것은 서버다. 여기 두는 것은 CLI 가 올리기 전에 미리 보게 하려는 것이다
/// (이슈 #70). 상한을 넘는 본문은 서버가 다 받기 전에 끊어서, 부른 쪽에는 이유 없는
/// 연결 오류만 남기도 한다.
public enum AppScreenshotLimits {
    /// 앱 하나에 둘 수 있는 수.
    public static let maximumCount = 5
    /// 한 장의 크기. 레티나 전체 화면 PNG 도 보통 이 안에 든다.
    public static let maximumSize = 5 * 1024 * 1024
}
