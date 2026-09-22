import AlleyShared
import Foundation

/// 에이전트가 부를 수 있는 것들 (ADR-0060).
///
/// **릴리스 한 번에 필요한 것만 낸다.** 앱 삭제나 멤버 변경은 넣지 않는다. 사람
/// 토큰 자체는 그것도 할 수 있지만(ADR-0060 의 나쁜 점), 도구로 내주면 모델이 부를 수
/// 있는 것이 된다. 돌이킬 수 없는 일은 화면에서 사람이 한다.
///
/// 설계에 적은 다섯에 `list_apps` 를 더했다. 나머지 도구가 앱 id 를 받는데, 그것을
/// 얻을 길이 없으면 사람이 콘솔에서 복사해 와야 한다.
enum MCPToolbox {
    enum ToolError: Error, CustomStringConvertible {
        case unknownTool(String)
        case missingArgument(String)
        case badUUID(String)
        case appNotFound(String)

        var description: String {
            switch self {
            case .unknownTool(let name):
                return "모르는 도구입니다: \(name)"
            case .missingArgument(let name):
                return "\(name) 이 필요합니다."
            case .badUUID(let value):
                return "id 로 읽을 수 없습니다: \(value)"
            case .appNotFound(let value):
                return "그런 앱을 찾지 못했습니다: \(value). list_apps 로 이름을 확인하세요."
            }
        }
    }

    static let all: [MCPTool] = [
        MCPTool(
            name: "list_apps",
            description: """
                내가 올릴 수 있는 앱들. 다른 도구에 넣을 앱 id 를 여기서 얻는다. \
                앱을 이름으로 알고 있을 때 먼저 부른다.
                """,
            inputSchema: MCPTool.schema()
        ),
        MCPTool(
            name: "list_versions",
            description: """
                한 앱의 버전 목록. 상태(draft·signing·released·failed)와 빌드 번호가 \
                함께 온다. 무엇을 출시할지 고르거나 마지막 빌드 번호를 알아낼 때 쓴다.
                """,
            inputSchema: MCPTool.schema(required: ["app": "앱 id 또는 번들 ID"])
        ),
        MCPTool(
            name: "upload_version",
            description: """
                빌드한 zip 을 올린다. 올리면 서명 워커가 이어받는다. \
                **올린 뒤 signing_status 로 결과를 확인해야 한다.** 이 도구는 올리는 \
                것까지만 하고 서명을 기다리지 않는다. 공증까지 몇십 분 걸리는 일이 있어 \
                기다리면 도구 호출이 먼저 끊긴다.
                """,
            inputSchema: MCPTool.schema(
                required: [
                    "app": "앱 id 또는 번들 ID",
                    "file": "올릴 zip 의 경로",
                    "version": "버전 문자열. 예: 1.2.0",
                ],
                optional: [
                    "build": "빌드 번호. 비우면 마지막 것 다음으로 매긴다",
                    "notes": "릴리스 노트",
                    "entitlements": "entitlements plist 의 경로",
                ]
            )
        ),
        MCPTool(
            name: "signing_status",
            description: """
                한 버전의 서명이 어디까지 왔는지. **실패했으면 갈래(failureCode)와 \
                무엇을 하면 되는지(whatToDo)가 함께 온다.** 올린 뒤 결과를 확인하거나, \
                실패를 고칠 때 먼저 부른다.
                """,
            inputSchema: MCPTool.schema(required: ["version": "버전 id"])
        ),
        MCPTool(
            name: "release_version",
            description: """
                서명이 끝난 버전을 출시한다. 이때부터 사람들이 받아간다. \
                되돌릴 수 없으니 사람이 그러라고 했을 때만 부른다.
                """,
            inputSchema: MCPTool.schema(required: ["version": "버전 id"])
        ),
        MCPTool(
            name: "sparkle_feed",
            description: """
                Sparkle 을 쓰는 앱이 Info.plist 에 넣을 SUPublicEDKey 와, 지금 그 경로가 \
                실제로 도는 상태인지. 막혀 있으면 무엇이 막고 있는지(blocker)가 온다.
                """,
            inputSchema: MCPTool.schema(required: ["app": "앱 id 또는 번들 ID"])
        ),
        MCPTool(
            name: "app_feedback",
            description: """
                그 앱에 들어온 별점과 피드백. 버그 제보를 티켓으로 옮기거나 \
                무엇부터 고칠지 정할 때 쓴다.
                """,
            inputSchema: MCPTool.schema(required: ["app": "앱 id 또는 번들 ID"])
        ),
    ]

    static func run(
        _ name: String,
        arguments: [String: JSONValue],
        api: StoreAPI
    ) async throws -> JSONValue {
        switch name {
        case "list_apps":
            let apps = try await api.apps()
            return try MCPToolResult.json(apps.map(AppSummary.init))

        case "list_versions":
            let app = try await resolveApp(arguments, api: api)
            let versions = try await api.versions(ofApp: app.id)
            return try MCPToolResult.json(
                versions.sorted { $0.buildNumber > $1.buildNumber }
            )

        case "upload_version":
            let app = try await resolveApp(arguments, api: api)
            guard let path = arguments["file"]?.stringValue, !path.isEmpty else {
                throw ToolError.missingArgument("file")
            }
            guard let shortVersion = arguments["version"]?.stringValue, !shortVersion.isEmpty else {
                throw ToolError.missingArgument("version")
            }
            let entitlements = try arguments["entitlements"]?.stringValue.map {
                try String(contentsOfFile: $0, encoding: .utf8)
            }
            let uploaded = try await UploadCommand(api: api, log: { _ in })
                .run(
                    UploadCommand.Options(
                        file: URL(fileURLWithPath: path),
                        shortVersion: shortVersion,
                        buildNumber: arguments["build"]?.stringValue.flatMap(Int.init),
                        releaseNotes: arguments["notes"]?.stringValue,
                        entitlements: entitlements,
                        app: app
                    )
                )
            return try MCPToolResult.json(uploaded)

        case "signing_status":
            let versionID = try uuid(named: "version", in: arguments)
            return try MCPToolResult.json(try await api.signingStatus(versionID: versionID))

        case "release_version":
            let versionID = try uuid(named: "version", in: arguments)
            return try MCPToolResult.json(try await api.release(versionID: versionID))

        case "sparkle_feed":
            let app = try await resolveApp(arguments, api: api)
            return try MCPToolResult.json(try await api.sparkle(appID: app.id))

        case "app_feedback":
            let app = try await resolveApp(arguments, api: api)
            return try MCPToolResult.json(try await api.feedback(appID: app.id))

        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - 인자 읽기

    /// 앱을 id 로도 번들 ID 로도 받는다.
    ///
    /// **모델은 번들 ID 를 알고 있을 때가 많다.** 소스에 적혀 있기 때문이다. id 만
    /// 받으면 매번 `list_apps` 를 먼저 부르게 되고, 그 왕복이 도구를 쓸 때마다 붙는다.
    private static func resolveApp(
        _ arguments: [String: JSONValue],
        api: StoreAPI
    ) async throws -> AppDTO {
        guard let raw = arguments["app"]?.stringValue, !raw.isEmpty else {
            throw ToolError.missingArgument("app")
        }
        let apps = try await api.apps()
        if let id = UUID(uuidString: raw), let found = apps.first(where: { $0.id == id }) {
            return found
        }
        if let found = apps.first(where: { $0.bundleID.caseInsensitiveCompare(raw) == .orderedSame }) {
            return found
        }
        throw ToolError.appNotFound(raw)
    }

    private static func uuid(named name: String, in arguments: [String: JSONValue]) throws -> UUID {
        guard let raw = arguments[name]?.stringValue, !raw.isEmpty else {
            throw ToolError.missingArgument(name)
        }
        guard let id = UUID(uuidString: raw) else {
            throw ToolError.badUUID(raw)
        }
        return id
    }
}

/// 목록에 실어 보낼 앱 한 줄.
///
/// `AppDTO` 를 통째로 보내지 않는다. 아이콘 주소와 별점 같은 것이 매 호출마다
/// 모델의 창을 차지한다. 다른 도구에 넣을 값과 사람이 알아볼 이름만 남긴다.
struct AppSummary: Encodable {
    var id: UUID
    var bundleID: String
    var name: String

    init(_ app: AppDTO) {
        self.id = app.id
        self.bundleID = app.bundleID
        self.name = app.name
    }
}
