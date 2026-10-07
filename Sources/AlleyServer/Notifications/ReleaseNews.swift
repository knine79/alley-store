import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 새 버전을 앱의 출시 소식 채널에 알린다 (이슈 #63, ADR-0075).
///
/// 알릴지는 출시하는 사람이 그때마다 고른다. 여기는 고른 뒤의 일만 한다. 무엇을
/// 쓸지 정하고, 한 버전에 한 번만 올라가게 막고, 채널마다 결과를 남긴다.
///
/// **알림 실패가 출시를 막지 않는다.** 이미 출시는 저장된 뒤에 부른다. Slack 이
/// 거절해도 채널에 이유를 적고 넘어간다 (`Notifier` 와 같은 규칙).
enum ReleaseNews {
    /// 릴리즈 노트에서 실을 만큼. 채널은 읽으라고 올리는 곳이지 변경 기록이 아니다.
    static let noteLineLimit = 5
    static let noteCharacterLimit = 300
    /// 소개는 한 줄이어야 하지만 길이를 막는 곳이 없다. Slack 블록 하나는 3000자를
    /// 넘으면 통째로 거절된다.
    static let summaryCharacterLimit = 300

    /// 올릴 글.
    struct Message: Equatable, Sendable {
        /// 알림 미리보기와 블록을 못 그리는 곳에 쓰인다.
        var text: String
        var blocks: [SlackBlock]
    }

    // MARK: - 알리기

    /// 이 버전을 알린다. 이미 알렸거나 보낼 수 없으면 조용히 지나간다.
    ///
    /// `isFirstRelease` 는 출시 **전에** 정해서 넘긴다. 출시한 뒤에 세면 방금 출시한
    /// 이 버전이 끼어서 언제나 업데이트가 된다.
    static func announce(
        _ version: Version,
        of app: App,
        isFirstRelease: Bool,
        on request: Request
    ) async {
        let appID: UUID
        let versionID: UUID
        do {
            appID = try app.requireID()
            versionID = try version.requireID()
        } catch {
            return
        }

        guard let bot = request.application.slackBot else {
            request.logger.info("Slack 봇이 없어 출시 소식을 보내지 않습니다 [\(app.bundleID)]")
            return
        }
        let channels = (try? await ReleaseChannel.query(on: request.db)
            .filter(\.$app.$id == appID)
            .sort(\.$name)
            .all()) ?? []
        guard !channels.isEmpty else { return }

        // **먼저 차지한 요청만 보낸다.** 출시 버튼을 두 번 누르거나 웹과 API 가 동시에
        // 출시해도 한 번만 올라간다. 읽고 나서 쓰면 그 사이에 둘 다 "아직 안 알렸다" 를 본다.
        guard await claim(versionID: versionID, on: request.db) else {
            request.logger.info("이미 알린 버전이라 출시 소식을 건너뜁니다 [\(app.bundleID) \(version.shortVersion)]")
            return
        }

        let settings = try? await request.storeSettings()
        let message = compose(
            appName: app.name,
            summary: app.summary,
            shortVersion: version.shortVersion,
            releaseNotes: version.releaseNotes,
            isFirstRelease: isFirstRelease,
            storeName: settings?.storeName ?? "Alley Store",
            link: App.absolute(
                AppLink.webPath(appID: appID),
                base: request.application.alleyConfig.publicBaseURL
            ) ?? AppLink.webPath(appID: appID)
        )

        // **채널마다 동시에 보낸다.** 출시는 이미 저장됐고 응답은 이것을 기다린다.
        // 차례로 보내면 Slack 이 느릴 때 채널 수만큼 한도(5초)가 쌓인다.
        let outcomes = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, channel) in channels.enumerated() {
                let channelID = channel.slackChannelID
                group.addTask {
                    do {
                        try await bot.post(text: message.text, blocks: message.blocks, to: channelID)
                        return (index, nil)
                    } catch {
                        return (index, String(describing: error))
                    }
                }
            }
            var collected: [(Int, String?)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var delivered = 0
        for (index, failure) in outcomes {
            let channel = channels[index]
            if let failure {
                channel.lastError = failure
                request.logger.warning("출시 소식을 보내지 못했습니다 [채널: #\(channel.name), 이유: \(failure)]")
            } else {
                channel.lastSentAt = Date()
                channel.lastError = nil
                delivered += 1
            }
            try? await channel.save(on: request.db)
        }

        // **한 곳에도 못 보냈으면 알린 것으로 치지 않는다.** Slack 이 잠깐 죽었거나 봇
        // 토큰을 바꾸던 중이었을 수 있다. 적어둔 채로 두면 고친 뒤 철회했다 다시
        // 출시해도 다시 보낼 길이 없다.
        guard delivered > 0 else {
            await release(versionID: versionID, on: request.db)
            return
        }
        request.logger.notice(
            "출시 소식 [\(app.bundleID) \(version.shortVersion), 채널 \(delivered)/\(channels.count)곳]"
        )
    }

    /// 이 버전에 "알렸다" 를 적는다. 이미 적혀 있으면 false.
    private static func claim(versionID: UUID, on database: any Database) async -> Bool {
        guard let sql = database as? any SQLDatabase else { return false }
        let rows = try? await sql.raw(
            """
            UPDATE versions SET announced_at = now()
            WHERE id = \(bind: versionID) AND announced_at IS NULL
            RETURNING id
            """
        ).all()
        return !(rows ?? []).isEmpty
    }

    /// 차지한 것을 내려놓는다. 다음 출시 때 다시 보낼 수 있게 한다.
    private static func release(versionID: UUID, on database: any Database) async {
        guard let sql = database as? any SQLDatabase else { return }
        try? await sql.raw(
            "UPDATE versions SET announced_at = NULL WHERE id = \(bind: versionID)"
        ).run()
    }

    /// 이 앱이 처음 출시되는 것인가.
    ///
    /// 다른 버전이 지금 출시돼 있거나 예전에 알린 적이 있으면 업데이트다. 철회하면
    /// 출시 시각이 지워지므로 알린 시각도 함께 본다.
    static func isFirstRelease(of version: Version, on database: any Database) async throws -> Bool {
        let others = try await Version.query(on: database)
            .filter(\.$app.$id == version.$app.id)
            .filter(\.$id != version.requireID())
            .group(.or) {
                $0.filter(\.$releasedAt != nil).filter(\.$announcedAt != nil)
            }
            .count()
        return others == 0
    }

    // MARK: - 글

    /// 올릴 글을 만든다. 네트워크도 데이터베이스도 쓰지 않는다.
    static func compose(
        appName: String,
        summary: String?,
        shortVersion: String,
        releaseNotes: String?,
        isFirstRelease: Bool,
        storeName: String,
        link: String
    ) -> Message {
        let name = escaped(appName)
        let store = escaped(storeName)
        let version = escaped(shortVersion)
        let title = isFirstRelease
            ? "🎉\(name) \(version) \(KoreanParticle.subject(after: shortVersion)) \(store)에 출시되었습니다."
            : "✨\(name) \(version) \(KoreanParticle.direction(after: shortVersion)) 업데이트되었습니다."

        var headline = "*\(title)*"
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            let cut = summary.count > summaryCharacterLimit
                ? String(summary.prefix(summaryCharacterLimit)) + "…"
                : summary
            headline += "\n\(escaped(cut))"
        }

        var blocks: [SlackBlock] = [
            .context("\(store) 출시 소식"),
            .section(headline),
        ]
        if let notes = excerpt(of: releaseNotes) {
            blocks.append(.section(
                notes.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \(escaped(String($0)))" }
                    .joined(separator: "\n")
            ))
        }
        blocks.append(.section("<\(link)|\(store)에서 보기>"))

        return Message(text: title, blocks: blocks)
    }

    /// 릴리즈 노트 앞부분. 비었으면 nil.
    ///
    /// 줄 수와 글자 수 중 먼저 닿는 쪽에서 자르고, 잘랐으면 … 를 붙인다.
    static func excerpt(of notes: String?) -> String? {
        guard let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notes.isEmpty
        else { return nil }

        let lines = notes.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var kept = lines.prefix(noteLineLimit).joined(separator: "\n")
        var truncated = lines.count > noteLineLimit
        if kept.count > noteCharacterLimit {
            kept = String(kept.prefix(noteCharacterLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            truncated = true
        }
        return truncated ? kept + "…" : kept
    }

    /// Slack mrkdwn 에서 뜻을 갖는 세 글자를 바꾼다. 앱 이름에 `<` 가 있으면 링크로 읽힌다.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 받침에 따라 갈리는 조사.
///
/// 버전 번호 뒤에 붙는다. "1.0 이", "1.2 가" 처럼 숫자는 읽는 소리로 가른다. 읽는
/// 법을 모르는 글자로 끝나면 둘을 함께 적는다.
enum KoreanParticle {
    /// 이/가
    static func subject(after word: String) -> String {
        switch ending(of: word) {
        case .consonant, .rieul: return "이"
        case .vowel: return "가"
        case .unknown: return "이(가)"
        }
    }

    /// 으로/로. ㄹ 받침 뒤에는 "로" 다.
    static func direction(after word: String) -> String {
        switch ending(of: word) {
        case .consonant: return "으로"
        case .vowel, .rieul: return "로"
        case .unknown: return "(으)로"
        }
    }

    private enum Ending {
        case vowel, consonant, rieul, unknown
    }

    private static func ending(of word: String) -> Ending {
        guard let last = word.trimmingCharacters(in: .whitespaces).last else { return .unknown }
        // 영(0) 삼(3) 육(6) 은 받침이 있고, 일(1) 칠(7) 팔(8) 은 ㄹ 받침이다.
        switch last {
        case "0", "3", "6": return .consonant
        case "1", "7", "8": return .rieul
        case "2", "4", "5", "9": return .vowel
        default: break
        }
        guard let scalar = last.unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value)
        else { return .unknown }
        let final = (scalar.value - 0xAC00) % 28
        switch final {
        case 0: return .vowel
        case 8: return .rieul
        default: return .consonant
        }
    }
}
