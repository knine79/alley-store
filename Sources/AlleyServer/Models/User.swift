import AlleyShared
import Fluent
import Foundation
import Vapor

/// 스토어 사용자.
///
/// Google 계정과 1:1로 대응한다. 식별자는 이메일이 아니라 `googleSubject`(`sub` claim)다.
/// 이메일은 조직 안에서 바뀔 수 있지만 `sub` 는 계정이 살아 있는 한 바뀌지 않는다.
public final class User: Model, @unchecked Sendable {
    public static let schema = "users"

    @ID(key: .id)
    public var id: UUID?

    /// Google ID 토큰의 `sub` claim. 계정의 영구 식별자.
    @Field(key: "google_subject")
    public var googleSubject: String

    /// 소문자로 정규화해 저장한다.
    @Field(key: "email")
    public var email: String

    @Field(key: "name")
    public var name: String

    @OptionalField(key: "avatar_url")
    public var avatarURL: String?

    @Enum(key: "role")
    public var role: UserRole

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @OptionalField(key: "last_login_at")
    public var lastLoginAt: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        googleSubject: String,
        email: String,
        name: String,
        avatarURL: String? = nil,
        role: UserRole
    ) {
        self.id = id
        self.googleSubject = googleSubject
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.role = role
    }
}

extension User {
    public func toDTO() throws -> UserDTO {
        UserDTO(
            id: try requireID(),
            email: email,
            name: name,
            avatarURL: avatarURL,
            role: role
        )
    }
}

// MARK: - 마이그레이션

/// `UserRole` 을 PostgreSQL enum 타입으로 만든다.
///
/// 문자열 컬럼으로 두면 오타나 알 수 없는 값이 들어올 수 있다. enum 으로 두면
/// 데이터베이스가 막아준다. 대신 값을 추가할 때 마이그레이션이 필요하다.
public struct CreateUserRoleEnum: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        var builder = database.enum("user_role")
        for role in UserRole.allCases {
            builder = builder.case(role.rawValue)
        }
        _ = try await builder.create()
    }

    public func revert(on database: any Database) async throws {
        try await database.enum("user_role").delete()
    }
}

public struct CreateUser: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        let role = try await database.enum("user_role").read()

        try await database.schema(User.schema)
            .id()
            .field("google_subject", .string, .required)
            .field("email", .string, .required)
            .field("name", .string, .required)
            .field("avatar_url", .string)
            .field("role", role, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("last_login_at", .datetime)
            // 같은 Google 계정으로 두 개의 사용자 행이 생기면 권한과 이력이 갈린다.
            .unique(on: "google_subject")
            // 이메일은 조직 안에서 유일하다. 중복되면 사람이 헷갈린다.
            .unique(on: "email")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
