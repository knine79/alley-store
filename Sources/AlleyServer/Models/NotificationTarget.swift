import AlleyShared
import Fluent
import Foundation
import Vapor

/// 알림을 보낼 곳 하나.
///
/// 앱에 붙으면 그 앱의 피드백이 갈 곳이고, 앱이 비어 있으면 전역 대상이다. 워커가
/// 조용해졌다는 알림처럼 특정 앱과 무관한 것이 그리로 간다.
///
/// **엔드포인트는 비밀이다.** Slack Incoming Webhook URL 은 그 자체가 채널에 글을
/// 쓸 수 있는 자격증명이다. 그래서 화면과 API 에 다시 내려주지 않고, 목록에는
/// 사람이 붙인 이름만 보여준다.
public final class NotificationTarget: Model, @unchecked Sendable {
    public static let schema = "notification_targets"

    @ID(key: .id)
    public var id: UUID?

    /// 붙어 있는 앱. 전역 대상이면 비어 있다.
    @OptionalParent(key: "app_id")
    public var app: App?

    @Field(key: "kind")
    public var kindName: String

    public var kind: NotificationChannelKind {
        get { NotificationChannelKind(rawValue: kindName) ?? .slack }
        set { kindName = newValue.rawValue }
    }

    @Field(key: "name")
    public var name: String

    /// 웹훅 URL. 밖으로 나가지 않는다.
    @Field(key: "endpoint")
    public var endpoint: String

    @OptionalParent(key: "created_by")
    public var createdBy: User?

    /// 마지막으로 보내려다 실패한 이유. 성공하면 지운다.
    ///
    /// 알림은 조용히 실패하기 쉬운 기능이다. 아무도 안 받고 있는데 잘 되는 줄 아는
    /// 상태를 만들지 않으려고 마지막 실패를 남긴다.
    @OptionalField(key: "last_error")
    public var lastError: String?

    @OptionalField(key: "last_sent_at")
    public var lastSentAt: Date?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        appID: UUID?,
        kind: NotificationChannelKind,
        name: String,
        endpoint: String,
        createdByID: UUID?
    ) {
        self.$app.id = appID
        self.kindName = kind.rawValue
        self.name = name
        self.endpoint = endpoint
        self.$createdBy.id = createdByID
    }

    public func toDTO() throws -> NotificationTargetDTO {
        NotificationTargetDTO(
            id: try requireID(),
            appID: $app.id,
            kind: kind,
            name: name,
            // 여기가 무엇을 내보낼지 정하는 한 곳이다. 갈래가 늘면 컴파일러가
            // 여기를 다시 물어본다.
            endpoint: {
                switch kind {
                case .email: return endpoint
                case .slack, .slackDirectMessage: return nil
                }
            }(),
            createdAt: createdAt ?? Date()
        )
    }
}

// MARK: - 마이그레이션

public struct CreateNotificationTarget: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(NotificationTarget.schema)
            .id()
            .field("app_id", .uuid, .references(App.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("name", .string, .required)
            .field("endpoint", .string, .required)
            .field("created_by", .uuid, .references(User.schema, "id"))
            .field("last_error", .string)
            .field("last_sent_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(NotificationTarget.schema).delete()
    }
}
