/// 토큰 종류를 값만 보고 가리는 접두어.
///
/// 서버가 정의하고 있지만 CLI 도 알아야 한다. `alley mcp` 는 사람 토큰이 아니면
/// 뜨는 순간 그렇다고 말한다. 서버까지 가서야 알게 되면 에이전트 안에서 인증 실패만
/// 반복된다.
public enum UserTokenPrefix {
    /// 사람이 쥐는 토큰 (ADR-0060).
    public static let person = "alleyu_"
    /// CI 가 쓰는 앱별 배포 토큰 (ADR-0015).
    public static let deploy = "alleyd_"
}
