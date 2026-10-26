import Foundation

/// 앱 동영상의 상한 (이슈 #73, ADR-0079).
///
/// 지키는 것은 서버다. 여기 두는 것은 CLI 가 올리기 전에 크기를 미리 보게 하려는 것이다.
/// 길이는 파일을 읽어야 알아서 서버만 본다.
public enum AppVideoLimits {
    /// 파일 크기. 화면 녹화 1분이면 대개 이 안에 든다.
    public static let maximumSize = 50 * 1024 * 1024
    /// 길이(초). 받기 전에 무엇을 하는 앱인지 보여주는 자리라 길 필요가 없다.
    public static let maximumDuration: Double = 60
}
