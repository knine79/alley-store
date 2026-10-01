import Foundation

/// 앞말의 받침을 보고 조사를 고른다.
///
/// 알림에 "메모장 을(를) 1.2 로" 처럼 둘 다 적으면 기계가 쓴 문장으로 읽힌다. 앱 이름과
/// 버전은 그때그때 달라서 조사를 미리 정할 수 없으니, 마지막 글자를 보고 고른다.
///
/// 판단할 수 없는 글자(영문 등)는 둘 다 적는다. 틀린 조사를 붙이는 것보다 낫다.
enum Josa {
    /// 마지막 글자의 받침. 없으면 `.none`, 알 수 없으면 nil.
    enum Final: Equatable {
        case none
        /// ㄹ 받침. "으로" 대신 "로" 를 쓴다.
        case rieul
        case other
    }

    static func final(of word: String) -> Final? {
        guard let last = word.trimmingCharacters(in: .whitespaces).unicodeScalars.last else {
            return nil
        }
        // 한글 음절은 받침 번호가 (코드 - 0xAC00) % 28 이다. 0 이면 받침이 없고 8 이 ㄹ 이다.
        if (0xAC00...0xD7A3).contains(last.value) {
            switch (last.value - 0xAC00) % 28 {
            case 0: return Final.none
            case 8: return .rieul
            default: return .other
            }
        }
        // 숫자는 읽는 소리로 본다. 버전 끝자리가 대개 숫자다.
        switch last {
        case "2", "4", "5", "9": return Final.none          // 이, 사, 오, 구
        case "1", "7", "8": return .rieul                    // 일, 칠, 팔
        case "0", "3", "6": return .other                    // 영, 삼, 육
        default: return nil
        }
    }

    /// 을/를
    static func object(_ word: String) -> String {
        switch final(of: word) {
        case .none?: return word + "를"
        case .rieul?, .other?: return word + "을"
        case nil: return word + "을(를)"
        }
    }

    /// 으로/로
    static func direction(_ word: String) -> String {
        switch final(of: word) {
        case .none?, .rieul?: return word + "로"
        case .other?: return word + "으로"
        case nil: return word + "(으)로"
        }
    }
}
