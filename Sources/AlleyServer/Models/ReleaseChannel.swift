import Fluent
import Foundation
import Vapor

/// 앱의 출시 소식을 올릴 Slack 채널 하나 (ADR-0075).
///
/// **알림 대상(`NotificationTarget`)과 따로 둔다.** 그쪽은 앱 관리자가 받는 알림(피드백,
/// 서명 실패)이 가는 곳이고 웹훅 주소를 비밀로 쥔다. 이쪽은 사람들에게 새 버전을
/// 알리는 곳이고, 스토어의 봇이 채널 ID 로 올린다. 한 테이블에 두면 "이 앱 채널로
/// 보내라" 가 어느 쪽을 뜻하는지 쿼리마다 가려야 한다.
///
/// 채널 ID 는 비밀이 아니다. 봇이 그 채널에 들어가 있어야 올릴 수 있고, ID 만으로는
/// 아무것도 못 한다.
public final class ReleaseChannel: Model, @unchecked Sendable {
    public static let schema = "release_channels"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "app_id")
    public var app: App

    /// Slack 의 채널 ID (`C...`, 비공개면 `G...` 도 있다). 이름은 바뀌어도 이것은 그대로다.
    @Field(key: "slack_channel_id")
    public var slackChannelID: String

    /// 등록할 때의 채널 이름. `#` 없이 둔다. 목록과 팝업에 보여주는 용도다.
    @Field(key: "name")
    public var name: String

    @OptionalParent(key: "created_by")
    public var createdBy: User?

    /// 마지막으로 보내려다 실패한 이유. 성공하면 지운다.
    ///
    /// 봇이 채널에서 빠지면 그 뒤로는 조용히 실패한다. 목록에서 보이게 남긴다.
    @OptionalField(key: "last_error")
    public var lastError: String?

    @OptionalField(key: "last_sent_at")
    public var lastSentAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(appID: UUID, slackChannelID: String, name: String, createdByID: UUID?) {
        self.$app.id = appID
        self.slackChannelID = slackChannelID
        self.name = name
        self.$createdBy.id = createdByID
    }
}

// MARK: - 마이그레이션

public struct CreateReleaseChannel: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(ReleaseChannel.schema)
            .id()
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field("slack_channel_id", .string, .required)
            .field("name", .string, .required)
            .field("created_by", .uuid, .references(User.schema, "id"))
            .field("last_error", .string)
            .field("last_sent_at", .datetime)
            .field("created_at", .datetime)
            // 같은 채널을 두 번 넣으면 같은 소식이 두 번 올라간다.
            .unique(on: "app_id", "slack_channel_id")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(ReleaseChannel.schema).delete()
    }
}
