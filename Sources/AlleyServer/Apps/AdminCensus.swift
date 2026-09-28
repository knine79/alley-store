import Fluent
import SQLKit

/// "관리자가 한 명은 남는가" 를 세는 구간을 줄 세운다.
///
/// **세어보고 바꾸는 사이에 남이 끼어들면 답이 틀린다.** 마지막 관리자 둘이 같은
/// 순간에 나가면 둘 다 "나 말고 한 명 남았다" 를 보고 둘 다 나간다. 관리자가 없는
/// 스토어는 아무도 설정을 바꾸지 못하고, 역할을 올려줄 사람도 없다.
///
/// 세는 것을 트랜잭션 안으로 옮기는 것만으로는 막히지 않는다. Postgres 의 기본
/// 격리 수준(read committed)에서는 옆 트랜잭션이 아직 커밋하지 않은 변경이 보이지
/// 않아서, 둘 다 여전히 한 명을 센다.
///
/// **트랜잭션 단위 advisory lock 을 쓴다.** 잡은 트랜잭션이 끝나면 저절로 풀려서
/// 놓아주는 것을 잊을 자리가 없다. 부팅 마이그레이션이 쓰는 세션 단위 잠금
/// (`AdvisoryLock`)과 다른 물건이다. 그쪽은 트랜잭션 여러 개를 통째로 감싸야 해서
/// 커넥션을 직접 들고 있어야 한다.
///
/// 이 잠금을 잡는 자리는 관리자 수를 **세고 나서 바꾸는** 모든 곳이다. 한 곳이라도
/// 빠뜨리면 그 길로 들어온 요청이 남을 기다리지 않아 잠금이 없는 것과 같아진다.
/// 지금은 역할 변경(`changeRole`)과 직접 탈퇴(`withdraw`) 둘이다.
enum AdminCensus {
    /// `AdvisoryLock.Purpose` 와 같은 이름 공간을 쓴다. 상위 32비트는 Alley 고유값
    /// (ASCII `"ally"`)이고 하위 32비트가 용도다. 한 번 나간 숫자는 다시 쓰지 않는다.
    private static let key: Int64 = 0x616C_6C79 << 32 | 2

    /// 이 트랜잭션이 끝날 때까지 관리자 수를 건드리는 다른 요청을 기다리게 한다.
    ///
    /// 반드시 트랜잭션 안에서 부른다. 밖에서 부르면 Postgres 가 그 자리에서 잠금을
    /// 잡았다 놓아 아무것도 지키지 못한다.
    static func lock(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            // 테스트가 아닌 곳에서는 언제나 Postgres 다. 잠그지 못했다고 일을
            // 멈추면 붙는 데이터베이스를 바꿀 때 기능이 통째로 죽는다.
            database.logger.warning("SQL 을 쓸 수 없어 관리자 수 잠금을 건너뜁니다.")
            return
        }
        try await sql.raw("SELECT pg_advisory_xact_lock(\(bind: key))").run()
    }
}
