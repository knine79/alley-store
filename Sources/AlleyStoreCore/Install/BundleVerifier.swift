import AlleyProcess
import CryptoKit
import Foundation

/// 설치 직전에 받은 파일을 검사한다.
///
/// **이 검사가 이 앱의 존재 이유에 가깝다.** 사내 배포는 App Store 심사를 거치지
/// 않으므로, 받은 것이 우리가 서명한 것이 맞는지 확인하는 일을 우리가 한다.
/// 서버가 뚫려 엉뚱한 바이너리가 올라갔더라도 여기서 걸려야 한다.
///
/// 세 가지를 본다.
/// 1. 서버가 알려준 SHA-256 과 받은 파일이 같은가 (전송 중 손상·중간 교체)
/// 2. 번들의 서명이 유효하고 공증까지 받았는가 (Gatekeeper 와 같은 판단)
/// 3. 서명한 팀이 이미 설치된 같은 앱과 같은 팀인가 (다른 팀 앱으로의 바꿔치기)
enum BundleVerifier {
    enum VerificationError: LocalizedError {
        case hashMismatch(expected: String, actual: String)
        case signatureInvalid(detail: String)
        case notNotarized(detail: String)
        case teamMismatch(installed: String, incoming: String)

        var errorDescription: String? {
            switch self {
            case .hashMismatch(let expected, let actual):
                return """
                    받은 파일이 서버가 알려준 것과 다릅니다. 설치하지 않았습니다.
                    기대한 해시: \(expected)
                    받은 해시: \(actual)
                    """
            case .signatureInvalid(let detail):
                return "서명을 확인할 수 없어 설치하지 않았습니다.\n\(detail)"
            case .notNotarized(let detail):
                return "공증을 확인할 수 없어 설치하지 않았습니다.\n\(detail)"
            case .teamMismatch(let installed, let incoming):
                return """
                    이미 설치된 앱과 서명한 팀이 다릅니다. 설치하지 않았습니다.
                    설치된 앱: \(installed)
                    받은 앱: \(incoming)
                    """
            }
        }
    }

    // MARK: - 해시

    /// 파일의 SHA-256 을 16진수 소문자로.
    ///
    /// 조각내어 읽는다. 수백 MB 짜리 앱을 통째로 메모리에 올릴 이유가 없다.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 서버가 알려준 해시와 대조한다.
    ///
    /// 서버가 해시를 모르는 경우가 있다(웹 콘솔로 완성본을 올린 경우, ADR-0012).
    /// 그때는 대조할 것이 없으므로 통과시킨다. 서명과 공증 검사가 남아 있다.
    static func verifyHash(of file: URL, expected: String?) throws {
        guard let expected = expected?.lowercased(), !expected.isEmpty else { return }
        let actual = try sha256(of: file)
        guard actual == expected else {
            throw VerificationError.hashMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: - 서명과 공증

    /// 번들의 서명과 공증을 확인한다.
    ///
    /// `codesign` 은 서명이 유효한지만 본다. 공증 여부는 `spctl` 이 판단한다. Gatekeeper
    /// 가 실제로 쓰는 것이 `spctl` 이라, 이걸 통과하면 사용자가 실행할 때도 통과한다.
    static func verifySignature(of bundle: URL) async throws {
        let signature = await Shell.runDetached(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", bundle.path]
        )
        guard signature.succeeded else {
            throw VerificationError.signatureInvalid(detail: signature.combinedOutput)
        }

        let gatekeeper = await Shell.runDetached(
            "/usr/sbin/spctl",
            ["--assess", "--type", "execute", "--verbose=2", bundle.path]
        )
        guard gatekeeper.succeeded else {
            throw VerificationError.notNotarized(detail: gatekeeper.combinedOutput)
        }
    }

    // MARK: - 팀 확인

    /// 번들에 서명한 팀 식별자.
    static func teamIdentifier(of bundle: URL) async -> String? {
        let result = await Shell.runDetached(
            "/usr/bin/codesign",
            ["--display", "--verbose=2", bundle.path]
        )
        // codesign 은 이 정보를 표준 오류로 낸다. 성공해도 그렇다.
        return teamIdentifier(fromCodesignOutput: result.combinedOutput)
    }

    /// `codesign --display` 출력에서 팀 식별자만 뽑는다.
    ///
    /// 출력은 `키=값` 이 줄마다 놓인 형태다. 순서가 보장되지 않아 줄 번호로 찾지 않는다.
    static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            // 서명이 없는 번들에서는 not set 이 온다.
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }

    /// 이미 깔린 앱과 같은 팀이 서명했는지 본다.
    ///
    /// 다르면 막는다. 같은 번들 ID 를 쓰는 다른 팀의 앱으로 바꿔치기하는 경로를
    /// 여기서 끊는다. 설치된 앱이 없거나 서명이 없으면 비교할 것이 없으므로 통과한다.
    static func verifyTeam(incoming: String?, installed: String?) throws {
        guard let installed, let incoming, installed != incoming else { return }
        throw VerificationError.teamMismatch(installed: installed, incoming: incoming)
    }
}
