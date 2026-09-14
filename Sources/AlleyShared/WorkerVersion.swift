/// 워커의 버전. **여기가 유일한 진실이다** (ADR-0042).
///
/// 번들의 `CFBundleShortVersionString` 도 빌드 스크립트가 이 값을 읽어 박는다.
/// 두 곳에서 관리하면 반드시 어긋나고, 어긋난 순간 "어느 워커가 도는가" 를 알 수
/// 없게 된다. 이번에 dmg 를 zip 으로 풀던 워커가 정확히 그 상태였다.
///
/// 서버도 자기가 아는 버전을 이 상수로 안다. 워커가 하트비트에 실어 보낸 값과
/// 비교해 낡았는지 판단한다.
public enum WorkerVersion {
    /// 올릴 때마다 커진다. 서버와 워커가 문자열로 비교하지 않고 숫자로 견준다.
    public static let current = "0.3.0"

    /// `1.2.3` 을 견줄 수 있는 형태로 바꾼다. 못 읽으면 nil.
    ///
    /// 문자열 비교로는 `0.10.0` 이 `0.9.0` 보다 작다고 나온다. 그 실수는 조용해서
    /// "낡았다" 는 경고가 안 뜨거나 멀쩡한 워커에 뜬다.
    public static func parts(of version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard let value = Int(piece), value >= 0 else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// `left` 가 `right` 보다 낮은가. 둘 중 하나라도 못 읽으면 판단하지 않는다(false).
    ///
    /// **모르면 경고하지 않는다.** 형식이 낯설다고 낡았다고 단정하면, 다음에 버전
    /// 규칙을 바꿀 때 멀쩡한 워커가 전부 빨갛게 뜬다.
    public static func isOlder(_ left: String, than right: String) -> Bool {
        guard let a = parts(of: left), let b = parts(of: right) else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}
