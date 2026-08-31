import AlleyCLICore
import Foundation

// 로직은 AlleyCLICore 에 있다. 여기서는 인자를 넘기고 종료 코드를 돌려주기만 한다.
// 실행 타깃에 코드를 두면 테스트가 그것을 임포트할 수 없다.
let code = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code.rawValue)
