import AlleyShared
import Fluent
import Foundation
import Vapor

/// 사용자가 버전 하나에 남긴 별점과 의견.
///
/// **익명은 화면에서만 익명이다.** 서버는 누가 남겼는지 계속 알고 있다. 그래야
/// 본인이 고치고 지울 수 있고, 악용이 생겼을 때 추적할 수 있다. 화면에 이름을
/// 띄우지 않을 뿐이다.
///
/// 사람 하나가 버전 하나에 하나만 남긴다. 같은 사람이 같은 빌드에 대해 두 번 말할
/// 이유가 없고, 생각이 바뀌면 고치면 된다. 다음 빌드에는 다시 남길 수 있다.
public final class Feedback: Model, @unchecked Sendable {
    public static let schema = "feedback"

    @ID(key: .id)
    public var id: UUID?

    /// 버전에 달리지만 앱으로도 조회한다. 관계를 거쳐 세면 목록 화면에서 N+1 이 된다.
    @Parent(key: "app_id")
    public var app: App

    @Parent(key: "version_id")
    public var version: Version

    @Parent(key: "user_id")
    public var user: User

    /// 1~5. 글만 남겼으면 비어 있다.
    @OptionalField(key: "rating")
    public var rating: Int?

    @OptionalField(key: "body")
    public var body: String?

    /// 첨부한 스크린샷의 스토리지 키.
    @OptionalField(key: "screenshot_key")
    public var screenshotKey: String?

    @Field(key: "is_anonymous")
    public var isAnonymous: Bool

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        appID: UUID,
        versionID: UUID,
        userID: UUID,
        rating: Int? = nil,
        body: String? = nil,
        isAnonymous: Bool = false
    ) {
        self.$app.id = appID
        self.$version.id = versionID
        self.$user.id = userID
        self.rating = rating
        self.body = body
        self.isAnonymous = isAnonymous
    }
}

extension Feedback {
    /// 스크린샷이 놓이는 자리.
    ///
    /// 아티팩트와 같은 버킷을 쓰되 경로를 나눈다. 앱 바이너리와 사용자가 올린
    /// 이미지는 수명도 다르고 지우는 기준도 다르다.
    public static func screenshotKey(feedbackID: UUID) -> String {
        "feedback/\(feedbackID.uuidString)/screenshot"
    }

    /// 화면에 내보낼 형태로 바꾼다.
    ///
    /// - Parameters:
    ///   - viewer: 지금 보는 사람. 자기 것인지 판단하고, 익명이라도 오너에게는
    ///             보여줄지 결정하는 자리다.
    ///   - revealAuthor: 익명이어도 이름을 보여줄지. 지금은 언제나 false 다.
    public func toDTO(
        viewer: User?,
        screenshotURL: String? = nil,
        revealAuthor: Bool = false
    ) throws -> FeedbackDTO {
        let author: UserDTO?
        if isAnonymous, !revealAuthor {
            author = nil
        } else {
            author = try $user.value.map { try $0.toDTO() }
        }

        let viewerID = try viewer?.requireID()
        return FeedbackDTO(
            id: try requireID(),
            appID: $app.id,
            versionID: $version.id,
            versionName: $version.value.map { "\($0.shortVersion) (\($0.buildNumber))" } ?? "",
            rating: rating,
            body: body,
            screenshotURL: screenshotURL,
            author: author,
            isAnonymous: isAnonymous,
            isMine: viewerID != nil && viewerID == $user.id,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }
}

// MARK: - 별점 집계

extension Feedback {
    /// 앱 하나의 별점 요약.
    static func summary(ofApp appID: UUID, on database: any Database) async throws -> RatingSummary {
        let ratings = try await Feedback.query(on: database)
            .filter(\.$app.$id == appID)
            .filter(\.$rating != nil)
            .all()
            .compactMap(\.rating)

        return summary(of: ratings)
    }

    /// 여러 앱의 별점을 한 번에 센다.
    ///
    /// 목록 화면이 앱마다 따로 세면 N+1 이 된다.
    static func summaries(
        ofApps appIDs: [UUID],
        on database: any Database
    ) async throws -> [UUID: RatingSummary] {
        guard !appIDs.isEmpty else { return [:] }

        let rows = try await Feedback.query(on: database)
            .filter(\.$app.$id ~~ appIDs)
            .filter(\.$rating != nil)
            .all()

        return Dictionary(grouping: rows, by: { $0.$app.id })
            .mapValues { summary(of: $0.compactMap(\.rating)) }
    }

    static func summary(of ratings: [Int]) -> RatingSummary {
        guard !ratings.isEmpty else { return RatingSummary(count: 0) }
        let total = ratings.reduce(0, +)
        return RatingSummary(
            count: ratings.count,
            average: Double(total) / Double(ratings.count)
        )
    }
}

// MARK: - 마이그레이션

public struct CreateFeedback: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Feedback.schema)
            .id()
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field(
                "version_id", .uuid, .required,
                .references(Version.schema, "id", onDelete: .cascade)
            )
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("rating", .int)
            .field("body", .string)
            .field("screenshot_key", .string)
            .field("is_anonymous", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // 사람 하나가 버전 하나에 하나만 남긴다. 생각이 바뀌면 고치면 된다.
            .unique(on: "version_id", "user_id")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Feedback.schema).delete()
    }
}
