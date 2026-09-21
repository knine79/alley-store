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

    /// 내가 올린 버전의 서명이 실패했을 때 받을지.
    ///
    /// **기본이 켜짐이다.** 내가 올린 것만 오므로 소음이 아니고, 실패를 모른 채로
    /// 두는 것이 이 알림을 만든 이유다. 끄고 싶은 사람만 끈다.
    @Field(key: "notify_signing_failure")
    public var notifySigningFailure: Bool

    /// 내가 올릴 수 있는 앱에 피드백이 왔을 때 받을지.
    ///
    /// **기본이 켜짐이다** (ADR-0059). 한때 꺼짐이었는데, 그러면 앱이 개별 전송으로
    /// 정해져 있어도 아무도 안 받는다. 기본이 꺼짐인 알림은 그 알림이 필요한 순간에
    /// 꺼져 있다. 소음을 겪은 사람이 끄면 되고, 그 사람은 끄는 자리를 찾아간다.
    @Field(key: "notify_feedback")
    public var notifyFeedback: Bool

    /// 나에게 오는 알림을 무엇으로 받을지.
    ///
    /// **개인이 정한다.** Slack 을 안 쓰는 사람이 있고, 봇 토큰을 받지 못한 스토어도
    /// 있다. 관리자가 정해두면 그 둘 중 한쪽은 알림을 못 받는다.
    ///
    /// 스토어가 그 수단을 갖추지 않았으면 고른 값이 그대로 있어도 쓸 수 있는 쪽으로
    /// 간다 (`Notifier.notify(person:)`). 고를 때는 없던 수단이 나중에 생기기도
    /// 하고, 있던 수단이 사라지기도 한다.
    @Field(key: "notify_via")
    public var notifyViaName: String

    public var notifyVia: NotificationChannelKind {
        get {
            let stored = NotificationChannelKind(rawValue: notifyViaName)
            // 사람에게 보낼 수 없는 값이 들어와 있으면 기본으로 되돌린다. 웹훅
            // 주소로는 그 사람에게만 보낼 수 없다.
            guard let stored, NotificationChannelKind.personal.contains(stored) else {
                return .slackDirectMessage
            }
            return stored
        }
        set { notifyViaName = newValue.rawValue }
    }

    public init() {}

    public init(
        id: UUID? = nil,
        issuer: String = AppConfig.OAuthConfig.googleIssuer,
        subject: String,
        email: String,
        name: String,
        avatarURL: String? = nil,
        role: UserRole,
        roleSetByAdmin: Bool = false,
        notifySigningFailure: Bool = true,
        notifyFeedback: Bool = true,
        notifyVia: NotificationChannelKind = .slackDirectMessage
    ) {
        self.id = id
        self.issuer = issuer
        self.subject = subject
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.role = role
        self.roleSetByAdmin = roleSetByAdmin
        self.notifySigningFailure = notifySigningFailure
        self.notifyFeedback = notifyFeedback
        self.notifyViaName = notifyVia.rawValue
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
        // **다시 돌려도 되게 둔다.** 아래 기본값 바꾸기가 실패하면 이 마이그레이션은
        // 기록되지 않는데 칸은 이미 생겨 있다. 되돌리기 쪽도 마찬가지로, 칸이 없는데
        // 기록만 남은 상태에서 죽으면 그 뒤 마이그레이션이 전부 멈춘다.
        try await sql.raw(
            """
            ALTER TABLE users
            ADD COLUMN IF NOT EXISTS role_set_by_admin boolean NOT NULL DEFAULT true
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
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS role_set_by_admin").run()
    }
}

public enum MigrationError: Error, CustomStringConvertible {
    case needsSQLDatabase

    public var description: String {
        "이 마이그레이션은 SQL 데이터베이스에서만 돌릴 수 있습니다."
    }
}

/// 개인 알림 선호를 담을 칸 둘.
///
/// 기본값이 서로 다르다. 서명 실패는 내가 올린 것만 오므로 켜두고, 피드백은 앱
/// 하나를 여럿이 맡으면 여러 통이 가므로 꺼둔다. 그 판단은 모델 주석에 적었다.
public struct AddNotificationPreferencesToUser: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("notify_signing_failure", .bool, .required, .sql(.default(true)))
            .field("notify_feedback", .bool, .required, .sql(.default(false)))
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("notify_signing_failure")
            .deleteField("notify_feedback")
            .update()
    }
}

/// 나에게 오는 알림을 무엇으로 받을지 (ADR-0058).
///
/// 기본값을 Slack DM 으로 둔다. 이 칸이 생기기 전에는 그것뿐이었으므로, 이미 켜둔
/// 사람의 받는 곳을 마이그레이션이 바꾸지 않는다. 메일만 갖춘 스토어에서는 값이
/// 그대로여도 메일로 간다 (`Notifier.notify(person:)`).
public struct AddNotifyViaToUser: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field(
                "notify_via",
                .string,
                .required,
                .sql(.default(NotificationChannelKind.slackDirectMessage.rawValue))
            )
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("notify_via")
            .update()
    }
}

/// 피드백 알림의 기본값을 켜짐으로 바꾼다 (ADR-0059).
///
/// **이미 정한 사람의 값은 건드리지 않는다.** 켠 사람은 켜져 있고 끈 사람은 꺼져
/// 있다. 여기서 바꾸는 것은 앞으로 만들어지는 계정의 기본값뿐이다.
///
/// 지금까지 꺼져 있던 사람들을 켜주지 않는 이유는, 그들이 끈 것인지 기본값을 그대로
/// 둔 것인지 구분할 수 없기 때문이다. 끈 사람을 다시 켜면 끄는 버튼이 눌러도 되돌아
/// 오는 버튼이 된다.
public struct DefaultFeedbackNotificationsOn: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE users ALTER COLUMN notify_feedback SET DEFAULT true").run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE users ALTER COLUMN notify_feedback SET DEFAULT false").run()
    }
}
