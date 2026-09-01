import AlleyShared
import Foundation

/// Sparkle 이 읽는 appcast XML.
///
/// Sparkle 은 RSS 2.0 에 자기 네임스페이스를 얹은 형식을 읽는다. 라이브러리를 쓰지
/// 않고 문자열로 만든다. 항목이 열 줄 남짓이고, XML 라이브러리를 들이면 이스케이프
/// 규칙을 그쪽에 맡기는 대신 그 동작을 다시 확인해야 한다.
///
/// **이스케이프가 이 파일의 핵심이다.** 앱 이름과 릴리즈 노트는 사람이 적는 값이고,
/// 거기 `&` 하나가 들어가면 Sparkle 이 피드 전체를 못 읽는다. 업데이트가 조용히
/// 멈추고, 아무도 모른다.
enum Appcast {
    /// 피드에 실을 항목 하나.
    struct Item {
        var shortVersion: String
        var buildNumber: Int
        var releaseNotes: String?
        var minimumSystemVersion: String?
        var publishedAt: Date
        var downloadURL: String
        var fileSize: Int64?
        /// Sparkle 이 요구하는 EdDSA 서명. 없으면 Sparkle 이 설치를 거부한다.
        var edSignature: String?
    }

    static func xml(appName: String, items: [Item]) -> String {
        let entries = items.map(entry(for:)).joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <title>\(escape(appName))</title>
            \(entries)
              </channel>
            </rss>
            """
    }

    private static func entry(for item: Item) -> String {
        var lines = [
            "    <item>",
            "      <title>\(escape(item.shortVersion))</title>",
            "      <pubDate>\(rfc822(item.publishedAt))</pubDate>",
            "      <sparkle:version>\(item.buildNumber)</sparkle:version>",
            "      <sparkle:shortVersionString>\(escape(item.shortVersion))</sparkle:shortVersionString>",
        ]

        if let minimum = item.minimumSystemVersion, !minimum.isEmpty {
            lines.append(
                "      <sparkle:minimumSystemVersion>\(escape(minimum))</sparkle:minimumSystemVersion>"
            )
        }
        if let notes = item.releaseNotes, !notes.isEmpty {
            lines.append("      <description>\(escape(notes))</description>")
        }

        var enclosure = "      <enclosure url=\"\(escape(item.downloadURL))\""
        if let size = item.fileSize {
            enclosure += " length=\"\(size)\""
        }
        enclosure += " type=\"application/octet-stream\""
        if let signature = item.edSignature, !signature.isEmpty {
            enclosure += " sparkle:edSignature=\"\(escape(signature))\""
        }
        enclosure += "/>"

        lines.append(enclosure)
        lines.append("    </item>")
        return lines.joined(separator: "\n")
    }

    /// XML 에서 뜻을 갖는 문자를 전부 바꾼다.
    ///
    /// 속성값 안에도 들어가므로 따옴표까지 바꾼다. CDATA 를 쓰지 않는 이유는 릴리즈
    /// 노트에 `]]>` 가 들어가는 경우를 또 다뤄야 하기 때문이다. 이스케이프 한 가지로
    /// 끝내는 편이 확인할 것이 적다.
    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// RSS 가 요구하는 날짜 형식.
    ///
    /// 로케일을 고정한다. 시스템 로케일을 따르면 한국어 환경에서 "9월"처럼 나가고,
    /// 그건 RFC 822 가 아니다.
    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
