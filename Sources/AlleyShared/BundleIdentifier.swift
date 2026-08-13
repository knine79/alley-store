import Foundation

/// 번들 ID 검증.
///
/// 번들 ID는 앱마다 고유해야 한다. macOS가 이 값으로 LaunchServices 등록,
/// UserDefaults 도메인, 키체인 접근 그룹, TCC 권한 승인 단위를 결정하기 때문이다.
/// 스토어는 프리픽스 준수와 중복을 막아 조직 안에서 ID가 난립하지 않게 한다.
public enum BundleIdentifier {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalidFormat
        case prefixMismatch(expected: String)

        public var description: String {
            switch self {
            case .empty:
                return "번들 ID가 비어 있습니다."
            case .invalidFormat:
                return "번들 ID는 점으로 구분된 역방향 도메인 형식이어야 합니다. 각 구간은 영문/숫자/하이픈만 쓸 수 있습니다."
            case .prefixMismatch(let expected):
                return "번들 ID는 '\(expected)' 로 시작해야 합니다."
            }
        }
    }

    /// 역방향 도메인 형식인지 확인한다.
    ///
    /// Apple 규칙에 맞춰 각 구간은 영숫자와 하이픈만 허용하고,
    /// 최소 두 구간(예: `com.example`) 이상이어야 한다.
    public static func isWellFormed(_ bundleID: String) -> Bool {
        let segments = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }

        return segments.allSatisfy { segment in
            guard !segment.isEmpty else { return false }
            // 하이픈으로 시작하거나 끝나는 구간은 거부한다.
            guard segment.first != "-", segment.last != "-" else { return false }
            return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// 형식과 프리픽스를 함께 검증한다.
    ///
    /// - Parameters:
    ///   - bundleID: 검증할 번들 ID.
    ///   - requiredPrefix: 강제할 프리픽스. 조직마다 다르므로 서버 설정에서 온다.
    ///                     `nil`이면 프리픽스를 강제하지 않는다.
    public static func validate(_ bundleID: String, requiredPrefix: String?) throws(ValidationError) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard isWellFormed(trimmed) else { throw .invalidFormat }

        if let requiredPrefix, !requiredPrefix.isEmpty {
            // 설정값에 끝점이 있든 없든 같게 다룬다.
            let normalized = requiredPrefix.hasSuffix(".") ? requiredPrefix : requiredPrefix + "."
            guard trimmed.hasPrefix(normalized) else {
                throw .prefixMismatch(expected: normalized)
            }
        }
    }
}
