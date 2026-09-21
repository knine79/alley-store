import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 스토어 사용자.
///
/// 로그인 공급자의 계정과 1:1로 대응한다. 식별자는 이메일이 아니라 `subject`(`sub`
/// claim)다. 이메일은 조직 안에서 바뀔 수 있지만 `sub` 는 계정이 살아 있는 한 바뀌지
/// 않는다.
///
/// **`sub` 는 공급자 안에서만 유일하다.** 그래서 `issuer` 와 짝으로 본다 (ADR-0047).
public final class User: Model, @unchecked Sendable {
    public static let schema = "users"

    @ID(key: .id)
    public var id: UUID?

    /// 이 계정을 발급한 OIDC 공급자. `https://accounts.google.com` 처럼 생겼다.
    @Field(key: "issuer")
    public var issuer: String

    /// ID 토큰의 `sub` claim. 그 공급자 안에서의 영구 식별자.
    @Field(key: "subject")
    public var subject: String

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

    /// 관리자가 이 사람의 역할을 손으로 정했나.
    ///
    /// **웹 콘솔로 들어온 사람은 자동으로 `developer` 가 된다** (ADR-0056). 그 승격이
    /// 관리자가 내린 결정을 매 로그인마다 되돌리면 안 된다. 관리자가 한 번이라도
    /// 역할을 정하면 이 값이 켜지고, 그 뒤로 자동 승격은 이 계정을 건너뛴다.
    ///
    /// 이 값이 없으면 "내려두면 다음 로그인에 다시 올라간다" 가 되어, 역할 화면이
    /// 눌리기는 하는데 아무것도 바뀌지 않는 버튼이 된다.
    @Field(key: "role_set_by_admin")
    public var roleSetByAdmin: Bool

    public init() {}

    public init(
        id: UUID? = nil,
        issuer: String = AppConfig.OAuthConfig.googleIssuer,
        subject: String,
        email: String,
        name: String,
        avatarURL: String? = nil,
        role: UserRole,
        roleSetByAdmin: Bool = false
    ) {
        self.id = id
        self.issuer = issuer
        self.subject = subject
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.role = role
        self.roleSetByAdmin = roleSetByAdmin
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
        // **값을 여기 그대로 적는다.** `allCases` 를 순회하면 이 마이그레이션이 코드를
        // 따라 움직인다. 역할을 하나 더하는 순간 새 데이터베이스는 그 값을 갖고
        // 시작하는데, 옛 데이터베이스를 위해 뒤에 붙인 마이그레이션은 이미 있는 값을
        // 또 넣으려다 죽는다. `artifact_kind` 가 그렇게 터졌다 (`CreateArtifact`).
        var builder = database.enum("user_role")
        for role in ["user", "developer", "admin"] {
            builder = builder.case(role)
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

/// 계정을 Google 전용에서 어떤 OIDC 공급자든 받도록 넓힌다 (ADR-0047).
///
/// `google_subject` 를 `subject` 로 바꾸고 `issuer` 를 더한다. **이미 있는 행은 전부
/// Google 에서 온 것이므로** 그 값으로 채운다. 그래야 지금 로그인해 있는 사람들이
/// 다음 로그인에서 같은 계정을 찾는다.
///
/// 유일성도 옮긴다. `sub` 는 공급자 안에서만 유일해서 `issuer` 와 짝이어야 한다.
///
/// Fluent 의 스키마 빌더에는 컬럼 이름을 바꾸는 방법이 없어서 SQL 을 직접 쓴다.
/// 이 레포가 이미 여러 자리에서 쓰는 길이다(`SigningJob`, `DownloadStats`).
public struct AddIssuerToUser: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }

        // 제약 이름은 Fluent 의 `unique(on:)` 이 붙인 것이다. 점과 `+` 가 들어 있어
        // 따옴표로 감싼다. 값이 아니라 식별자라 바인딩으로 넘길 수 없어서 그대로
        // 적는다. 바깥에서 오는 값이 없으므로 넣을 자리도 없다.
        try await sql.raw("ALTER TABLE users RENAME COLUMN google_subject TO subject").run()
        try await sql.raw(
            """
            ALTER TABLE users
            ADD COLUMN issuer text NOT NULL
            DEFAULT 'https://accounts.google.com'
            """
        ).run()
        // 기본값은 채우기용이다. 남겨두면 앞으로 들어오는 행이 공급자를 안 적어도
        // 조용히 Google 이 된다. 채웠으니 떼어낸다.
        try await sql.raw("ALTER TABLE users ALTER COLUMN issuer DROP DEFAULT").run()

        try await sql.raw(
            #"ALTER TABLE users DROP CONSTRAINT IF EXISTS "uq:users.google_subject""#
        ).run()
        try await sql.raw(
            #"""
            ALTER TABLE users
            ADD CONSTRAINT "uq:users.issuer+users.subject" UNIQUE (issuer, subject)
            """#
        ).run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw(
            #"ALTER TABLE users DROP CONSTRAINT IF EXISTS "uq:users.issuer+users.subject""#
        ).run()
        try await sql.raw("ALTER TABLE users DROP COLUMN issuer").run()
        try await sql.raw("ALTER TABLE users RENAME COLUMN subject TO google_subject").run()
        try await sql.raw(
            #"""
            ALTER TABLE users
            ADD CONSTRAINT "uq:users.google_subject" UNIQUE (google_subject)
            """#
        ).run()
    }
}

/// 관리자가 역할을 손으로 정했는지를 기록하는 칸을 만든다 (ADR-0056).
///
/// **이미 있는 계정은 전부 `true` 로 채운다.** 지금까지 역할은 사람이 정하는 것
/// 하나뿐이었다. `false` 로 깔면 그동안 `user` 로 두기로 한 계정들이 다음 로그인에
/// 조용히 `developer` 로 올라간다. 마이그레이션이 권한을 바꾸는 일은 없어야 한다.
public struct AddRoleSetByAdminToUser: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw(
            """
            ALTER TABLE users
            ADD COLUMN role_set_by_admin boolean NOT NULL DEFAULT true
            """
        ).run()
        // 기본값은 이미 있는 행을 채우려고 뒀다. 남겨두면 앞으로 만들어지는 계정도
        // "관리자가 정한 것" 으로 들어와 자동 승격을 영영 받지 못한다.
        try await sql.raw(
            "ALTER TABLE users ALTER COLUMN role_set_by_admin SET DEFAULT false"
        ).run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE users DROP COLUMN role_set_by_admin").run()
    }
}

public enum MigrationError: Error, CustomStringConvertible {
    case needsSQLDatabase

    public var description: String {
        "이 마이그레이션은 SQL 데이터베이스에서만 돌릴 수 있습니다."
    }
}
