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
///
/// 앱 상세(소개, 분류, 태그, 스크린샷)를 읽고 고치는 것도 낸다 (이슈 #70, ADR-0077).
/// 새 기능을 내면서 소개와 화면을 함께 바꾸는 것도 릴리스의 일이다. 고친 것은 다시
/// 고치면 되돌아간다. 번들 ID, 멤버, 토큰, 앱 삭제는 여전히 내지 않는다.
enum MCPToolbox {
    enum ToolError: Error, CustomStringConvertible {
        case unknownTool(String)
        case missingArgument(String)
        case badUUID(String)
        case appNotFound(String)
        case notANumber(String, String)
        case notAFlag(String, String)
        case notAList(String)
        case relativePath(String)
        case nothingToUpdate
        case unreadableFile(String)
        case screenshotNotFound(String)
        case tooLarge(String)

        /// 붙어 있는 쪽이 규약을 어긴 것인가.
        ///
        /// 없는 도구를 부르는 것은 도구 목록을 잘못 읽은 것이라 모델이 고칠 수 없다.
        /// 나머지(앱 이름 오타, 빠진 인자)는 모델이 읽고 다시 부르면 되는 사실이라
        /// 결과로 돌려준다.
        var isProtocolViolation: Bool {
            if case .unknownTool = self { return true }
            return false
        }

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
            case .notANumber(let name, let value):
                return "\(name) 은 숫자여야 합니다: \(value)"
            case .notAFlag(let name, let value):
                return "\(name) 은 true 나 false 여야 합니다: \(value)"
            case .notAList(let name):
                return "\(name) 은 문자열 배열이어야 합니다."
            case .relativePath(let value):
                return """
                    파일 경로는 절대 경로여야 합니다: \(value). 이 서버는 에이전트를 \
                    띄운 쪽의 디렉터리에서 돌기 때문에, 작업 디렉터리 기준 경로는 \
                    엉뚱한 자리를 가리킵니다.
                    """
            case .nothingToUpdate:
                return "바꿀 항목이 없습니다. name, summary, description, category, tags 중 하나는 넣으세요."
            case .unreadableFile(let path):
                return "파일을 읽지 못했습니다: \(path)"
            case .tooLarge(let path):
                return "\(path): 한 장에 \(AppScreenshotLimits.maximumSize / 1024 / 1024)MB 까지입니다."
            case .screenshotNotFound(let value):
                return "이 앱에 그런 스크린샷이 없습니다: \(value). app_details 로 id 를 확인하세요."
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
                한 앱의 버전 목록. 최신 빌드가 먼저 온다. 무엇을 출시할지 고르거나 \
                마지막 빌드 번호를 알아낼 때 쓴다. 상태는 draft·uploaded·signing· \
                notarizing·ready·released·failed 일곱 가지이고, **출시할 수 있는 것은 \
                ready 뿐이다.**
                """,
            inputSchema: MCPTool.schema(
                required: ["app": "앱 id 또는 번들 ID"],
                optional: ["limit": "몇 개까지 볼지. 비우면 20개"]
            )
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
                    "file": "올릴 zip 의 **절대** 경로",
                    "version": "버전 문자열. 예: 1.2.0",
                ],
                optional: [
                    "build": "빌드 번호. 비우면 마지막 것 다음으로 매긴다",
                    "notes": "릴리스 노트",
                    "min_os": "실행에 필요한 최소 macOS 버전. 예: 14.0",
                    "entitlements": "entitlements plist 의 절대 경로",
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
                상태가 ready 인 버전을 출시한다. 이때부터 사람들이 받아간다. \
                되돌릴 수 없으니 사람이 그러라고 했을 때만 부른다. \
                announce 를 "true" 로 주면 앱의 출시 소식 Slack 채널에도 알린다. \
                **알릴지는 사람에게 물어보고 정한다.** 안 주면 알리지 않는다. \
                결과의 shareURL 은 이 앱의 공유 링크다. 팀에 알릴 때 그대로 건네면 된다.
                """,
            inputSchema: MCPTool.schema(
                required: ["version": "버전 id"],
                optional: ["announce": "출시 소식 채널에 알릴지. \"true\" 또는 \"false\". 기본은 false"]
            )
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
                그 앱에 들어온 별점과 피드백. 최근 것이 먼저 온다. 버그 제보를 \
                티켓으로 옮기거나 무엇부터 고칠지 정할 때 쓴다.
                """,
            inputSchema: MCPTool.schema(
                required: ["app": "앱 id 또는 번들 ID"],
                optional: ["limit": "몇 개까지 볼지. 비우면 20개"]
            )
        ),
        MCPTool(
            name: "app_details",
            description: """
                스토어 앱 상세에 보이는 정보. 이름, 한 줄 소개(summary), 설명, 분류, 태그, \
                스크린샷 id 목록(보이는 순서), 개발자, 최신 출시본, 공유 링크. \
                update_app 이나 스크린샷 도구를 부르기 전에 지금 값을 확인할 때 쓴다. \
                스크린샷 그림 자체는 save_screenshots 로 받는다.
                """,
            inputSchema: MCPTool.schema(required: ["app": "앱 id 또는 번들 ID"])
        ),
        MCPTool(
            name: "update_app",
            description: """
                앱 상세의 글을 고친다. **넣은 항목만 바뀐다.** 빈 문자열은 넣지 않은 것으로 \
                본다. 앱 소유자와 관리자만 할 수 있다. 번들 ID 는 바꿀 수 없다. \
                사람들이 스토어에서 보는 글이니 바꿀 내용을 사람에게 먼저 보여준다.
                """,
            inputSchema: MCPTool.schema(
                required: ["app": "앱 id 또는 번들 ID"],
                optional: [
                    "name": "앱 이름",
                    "summary": "목록에 보이는 한 줄 소개",
                    "description": "상세에 보이는 설명",
                    "category": "분류. 다음 중 하나: \(categoryChoices)",
                    "tags": """
                        검색용 태그. **통째로 바꾼다.** 빈 배열이면 모두 뗀다. \
                        \(AppTags.maximumCount)개까지, 하나에 \(AppTags.maximumLength)자까지
                        """,
                ],
                lists: ["tags"]
            )
        ),
        MCPTool(
            name: "add_screenshots",
            description: """
                스크린샷을 덧붙인다. 앞에 준 것부터 차례로 뒤에 붙는다. PNG 나 JPEG, \
                한 장에 \(AppScreenshotLimits.maximumSize / 1024 / 1024)MB, 앱마다 \(AppScreenshotLimits.maximumCount)장까지. 자리가 모자라면 들어간 데까지만 올리고 \
                나머지를 알려준다. 바꾸려면 remove_screenshot 으로 먼저 지운다.
                """,
            inputSchema: MCPTool.schema(
                required: [
                    "app": "앱 id 또는 번들 ID",
                    "files": "올릴 그림 파일들의 **절대** 경로",
                ],
                lists: ["files"]
            )
        ),
        MCPTool(
            name: "remove_screenshot",
            description: """
                스크린샷 한 장을 지운다. 지운 그림은 되살릴 수 없으니 원본이 없으면 \
                save_screenshots 로 먼저 받아둔다.
                """,
            inputSchema: MCPTool.schema(
                required: [
                    "app": "앱 id 또는 번들 ID",
                    "screenshot": "app_details 가 준 스크린샷 id",
                ]
            )
        ),
        MCPTool(
            name: "save_screenshots",
            description: """
                지금 올라가 있는 스크린샷을 디렉터리에 받는다. 파일 이름 앞의 번호가 \
                보이는 순서다. 받은 경로를 돌려주니 그림을 열어 무엇이 찍혀 있는지 본다.
                """,
            inputSchema: MCPTool.schema(
                required: [
                    "app": "앱 id 또는 번들 ID",
                    "directory": "받을 디렉터리의 **절대** 경로. 없으면 만든다",
                ]
            )
        ),
    ]

    /// 분류로 넣을 수 있는 값. 화면 이름을 함께 적어 모델이 고르기 쉽게 한다.
    private static var categoryChoices: String {
        AppCategory.allCases.map { "\($0.rawValue)(\($0.title))" }.joined(separator: ", ")
    }

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
                .sorted { $0.buildNumber > $1.buildNumber }
            return try MCPToolResult.json(
                Array(versions.prefix(try limit(in: arguments)))
            )

        case "upload_version":
            let app = try await resolveApp(arguments, api: api)
            guard let path = arguments["file"]?.stringValue, !path.isEmpty else {
                throw ToolError.missingArgument("file")
            }
            guard let shortVersion = arguments["version"]?.stringValue, !shortVersion.isEmpty else {
                throw ToolError.missingArgument("version")
            }
            // 붙일 파일도 CLI 와 같은 검사를 지난다. plist 가 아닌 것을 서버까지
            // 보내면 서명 한 바퀴를 돈 뒤에야 알게 된다.
            let entitlements = try CLI.readEntitlements(
                at: try arguments["entitlements"]?.stringValue.map(absolutePath)
            )
            let uploaded = try await UploadCommand(api: api, log: { _ in })
                .run(
                    UploadCommand.Options(
                        file: URL(fileURLWithPath: try absolutePath(path)),
                        shortVersion: shortVersion,
                        buildNumber: try integer(named: "build", in: arguments),
                        releaseNotes: arguments["notes"]?.stringValue,
                        minimumOSVersion: arguments["min_os"]?.stringValue,
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
            return try MCPToolResult.json(
                try await api.release(
                    versionID: versionID, announce: try flag(named: "announce", in: arguments)
                )
            )

        case "sparkle_feed":
            let app = try await resolveApp(arguments, api: api)
            return try MCPToolResult.json(try await api.sparkle(appID: app.id))

        case "app_feedback":
            let app = try await resolveApp(arguments, api: api)
            let feedback = try await api.feedback(appID: app.id)
            return try MCPToolResult.json(
                Array(feedback.prefix(try limit(in: arguments)))
            )

        case "app_details":
            let app = try await resolveApp(arguments, api: api)
            return try MCPToolResult.json(AppDetails(try await api.app(id: app.id)))

        case "update_app":
            // 인자부터 본다. 고칠 것이 없는 호출로 서버를 다녀오지 않는다.
            let payload = UpdateAppRequest(
                name: text(named: "name", in: arguments),
                summary: text(named: "summary", in: arguments),
                description: text(named: "description", in: arguments),
                category: text(named: "category", in: arguments),
                tags: try list(named: "tags", in: arguments)
            )
            guard payload.name != nil || payload.summary != nil || payload.description != nil
                || payload.category != nil || payload.tags != nil
            else {
                throw ToolError.nothingToUpdate
            }
            let app = try await resolveApp(arguments, api: api)
            _ = try await api.updateApp(id: app.id, payload)
            return try MCPToolResult.json(try await details(of: app.id, api: api))

        case "add_screenshots":
            guard let paths = try list(named: "files", in: arguments), !paths.isEmpty else {
                throw ToolError.missingArgument("files")
            }
            // **올리기 전에 모두 읽는다.** 셋째 경로가 틀린 것을 둘을 올린 뒤에 알면,
            // 고쳐 부를 때 앞의 둘이 한 번 더 붙는다.
            let images = try paths.map { raw in
                let path = try absolutePath(raw)
                guard let data = FileManager.default.contents(atPath: path) else {
                    throw ToolError.unreadableFile(path)
                }
                // 상한을 넘는 본문은 서버가 다 받기 전에 끊어, 이유 없는 연결 오류만 남는다.
                guard data.count <= AppScreenshotLimits.maximumSize else {
                    throw ToolError.tooLarge(path)
                }
                return (path: path, data: data)
            }
            let app = try await resolveApp(arguments, api: api)
            return try MCPToolResult.json(try await addScreenshots(images, to: app.id, api: api))

        case "remove_screenshot":
            let screenshotID = try uuid(named: "screenshot", in: arguments)
            let app = try await resolveApp(arguments, api: api)
            do {
                _ = try await api.removeScreenshot(screenshotID, ofApp: app.id)
            } catch StoreAPI.APIError.server(status: 404, _) {
                throw ToolError.screenshotNotFound(screenshotID.uuidString.lowercased())
            }
            return try MCPToolResult.json(try await details(of: app.id, api: api))

        case "save_screenshots":
            let app = try await resolveApp(arguments, api: api)
            guard let raw = arguments["directory"]?.stringValue, !raw.isEmpty else {
                throw ToolError.missingArgument("directory")
            }
            let directory = URL(fileURLWithPath: try absolutePath(raw), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let screenshots = try await details(of: app.id, api: api).screenshots
            var saved: [String] = []
            for (index, id) in screenshots.enumerated() {
                do {
                    let data = try await api.screenshot(id, ofApp: app.id)
                    // 서버는 PNG 와 JPEG 만 받는다. 내용으로 가려 확장자를 붙여야 열어볼 때 헤매지 않는다.
                    let ext = data.starts(with: [0xFF, 0xD8, 0xFF]) ? "jpg" : "png"
                    let file = directory.appendingPathComponent(
                        "\(index + 1)-\(id.uuidString.lowercased()).\(ext)"
                    )
                    try data.write(to: file)
                    saved.append(file.path)
                } catch {
                    // 이미 받은 것은 디스크에 있다. 알리지 않으면 모델은 그 파일들을 모른다.
                    guard !saved.isEmpty else { throw error }
                    return try MCPToolResult.json(
                        SavedScreenshots(
                            files: saved,
                            notSaved: screenshots[index...].map(\.self),
                            reason: String(describing: error)
                        )
                    )
                }
            }
            return try MCPToolResult.json(SavedScreenshots(files: saved, notSaved: nil, reason: nil))

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
        // 도구를 부를 때마다 목록을 다시 받아오면 왕복이 두 배가 된다. 한 세션
        // 안에서 앱 목록은 거의 바뀌지 않는다.
        func find(in apps: [AppDTO]) -> AppDTO? {
            if let id = UUID(uuidString: raw), let found = apps.first(where: { $0.id == id }) {
                return found
            }
            return apps.first(where: { $0.bundleID.caseInsensitiveCompare(raw) == .orderedSame })
        }
        if let found = find(in: try await AppDirectory.shared.apps(using: api)) {
            return found
        }
        // **못 찾으면 한 번 다시 받는다.** 세션 도중에 앱이 등록되거나 공동 관리자로
        // 들어온 경우다. `list_apps` 는 매번 새로 받아서 그 앱이 보이는데, 여기서는 보인
        // 앱을 "없다" 고 답하게 된다. 그런 적이 있었다.
        if let found = find(in: try await AppDirectory.shared.reload(using: api)) {
            return found
        }
        throw ToolError.appNotFound(raw)
    }

    /// 목록을 몇 개까지 실을지.
    ///
    /// **한 번에 다 쏟지 않는다.** 피드백이 300개면 그것이 통째로 모델의 창을
    /// 차지한다. `AppSummary` 가 칸 셋을 아끼는 것과 같은 이유다.
    private static func limit(in arguments: [String: JSONValue]) throws -> Int {
        let given = try integer(named: "limit", in: arguments) ?? defaultLimit
        return max(1, min(given, maximumLimit))
    }

    static let defaultLimit = 20
    static let maximumLimit = 200

    /// 숫자 인자. 모델은 `42` 로도 `"42"` 로도 보낸다.
    ///
    /// **못 읽으면 말한다.** 조용히 nil 로 접으면 서버가 다음 번호를 매기고, 도구는
    /// 성공을 알린다. 부른 쪽은 자기가 적은 번호로 올라갔다고 믿는다.
    private static func integer(
        named name: String,
        in arguments: [String: JSONValue]
    ) throws -> Int? {
        guard let value = arguments[name], value != .null else { return nil }
        switch value {
        case .number(let number):
            return Int(number)
        case .string(let text) where !text.isEmpty:
            guard let parsed = Int(text) else { throw ToolError.notANumber(name, text) }
            return parsed
        case .string:
            return nil
        default:
            throw ToolError.notANumber(name, String(describing: value))
        }
    }

    /// 참/거짓 인자. 모델은 `true` 로도 `"true"` 로도 보낸다. 없으면 false.
    ///
    /// **못 읽으면 말한다.** 출시 소식처럼 사람들에게 나가는 것을 오타 하나로 조용히
    /// 끄거나 켜면 안 된다.
    private static func flag(named name: String, in arguments: [String: JSONValue]) throws -> Bool {
        guard let value = arguments[name], value != .null else { return false }
        switch value {
        case .bool(let flag):
            return flag
        case .string(let text):
            switch text.lowercased() {
            case "true": return true
            case "false", "": return false
            default: throw ToolError.notAFlag(name, text)
            }
        default:
            throw ToolError.notAFlag(name, String(describing: value))
        }
    }

    /// 글 인자. 비었으면 넣지 않은 것으로 본다.
    ///
    /// **빈 문자열로 지우게 하지 않는다.** 모델은 선택 인자를 빈 값으로 채워 보내기도
    /// 한다. 그것을 "지워라" 로 읽으면 이름 하나 고치려다 설명이 사라진다.
    private static func text(named name: String, in arguments: [String: JSONValue]) -> String? {
        guard let value = arguments[name]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    /// 문자열 배열 인자. 없으면 nil, 빈 배열은 빈 배열이다.
    ///
    /// 문자열 하나로 오면 한 개짜리로 본다. 파일 하나를 올릴 때 모델은 배열로 감싸지
    /// 않고 보내기도 한다.
    static func list(named name: String, in arguments: [String: JSONValue]) throws -> [String]? {
        guard let value = arguments[name], value != .null else { return nil }
        if let single = value.stringValue {
            return single.isEmpty ? nil : [single]
        }
        guard let items = value.arrayValue else { throw ToolError.notAList(name) }
        return try items.map {
            guard let item = $0.stringValue else { throw ToolError.notAList(name) }
            return item
        }
    }

    /// 스크린샷을 한 장씩 올린다.
    ///
    /// **중간에 막히면 거기서 멈추고 어디까지 됐는지 말한다.** 이미 올라간 것을 실패로
    /// 접으면 모델이 처음부터 다시 부르고, 앞의 것이 두 번 붙는다.
    private static func addScreenshots(
        _ images: [(path: String, data: Data)],
        to appID: UUID,
        api: StoreAPI
    ) async throws -> ScreenshotUpload {
        var added: [String] = []
        for (index, image) in images.enumerated() {
            do {
                _ = try await api.addScreenshot(image.data, toApp: appID)
                added.append(image.path)
            } catch {
                // 서버는 파일 이름을 모른다. 어느 것에서 막혔는지는 여기서 붙인다. 본문이
                // 상한을 넘으면 앱에 닿기 전에 잘려 서버의 설명도 붙지 않는다.
                var reason = "\(image.path): \(error)"
                if case StoreAPI.APIError.server(status: 413, _) = error {
                    reason = "\(image.path): 5MB 를 넘습니다."
                }
                // 응답 전에 끊겼으면 서버는 받았을 수도 있다. 다시 올리기 전에 보게 한다.
                if case StoreAPI.APIError.unreachable = error {
                    reason += " 올라갔는지는 app_details 로 확인하세요. 다시 올리면 두 번 붙을 수 있습니다."
                }
                // 하나도 못 올렸으면 그냥 실패다.
                guard !added.isEmpty else { throw ScreenshotUploadError(reason: reason) }
                return ScreenshotUpload(
                    added: added,
                    notAdded: images[index...].map(\.path),
                    reason: reason,
                    app: try? await details(of: appID, api: api)
                )
            }
        }
        return ScreenshotUpload(
            added: added, notAdded: nil, reason: nil, app: try? await details(of: appID, api: api)
        )
    }

    /// 고친 뒤의 앱을 다시 읽는다.
    ///
    /// 고치는 응답을 그대로 쓰지 않는다. 서버가 그 응답에는 개발자와 별점을 채우지 않아서,
    /// 같은 모양의 결과인데 `app_details` 와 달리 그 칸들이 빠진다. 모델은 그것을 지워진
    /// 것으로 읽는다. 한 번 더 다녀오는 값이 그보다 싸다.
    private static func details(of appID: UUID, api: StoreAPI) async throws -> AppDetails {
        AppDetails(try await api.app(id: appID))
    }

    /// 파일 경로는 절대 경로만 받는다.
    ///
    /// 이 프로세스의 작업 디렉터리는 에이전트를 띄운 쪽의 것이다. 모델이 자기 눈에
    /// 보이는 `build/MyApp.zip` 을 넘기면 엉뚱한 자리를 찾고, 돌아오는 말은 "그런
    /// 파일이 없습니다" 뿐이라 왜 없는지 알 수 없다.
    private static func absolutePath(_ raw: String) throws -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolError.relativePath(raw) }
        return expanded
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
    /// 번들 ID 가 아직 정해지지 않았나 (ADR-0034).
    ///
    /// **뺄 수 없는 칸이다.** dmg 로 올린 앱은 서버가 자리표시자를 넣어두는데, 그것을
    /// 진짜 ID 로 알고 설정에 적거나 사람에게 알리면 틀린 값이 퍼진다. 그 앱은 아직
    /// 출시할 수도 없다.
    var bundleIDPending: Bool?

    init(_ app: AppDTO) {
        self.id = app.id
        self.bundleID = app.bundleID
        self.name = app.name
        self.bundleIDPending = app.bundleIDPending == true ? true : nil
    }
}

/// 앱 상세에 보이는 것 (이슈 #70).
///
/// `AppDTO` 를 그대로 보내지 않는다. 스크린샷 주소는 토큰 없이 열리지 않아(ADR-0071)
/// 모델에게 쓸모가 없고, 지우거나 받을 때 넣을 id 만 있으면 된다. 아이콘 주소와 소유자
/// id 도 고칠 수 없는 값이라 뺀다.
struct AppDetails: Encodable {
    var id: UUID
    var bundleID: String
    var bundleIDPending: Bool?
    var name: String
    var summary: String?
    var description: String?
    /// 저장된 값(`developer-tools` 같은). update_app 에 그대로 넣을 수 있다.
    var category: String?
    var tags: [String]
    /// 보이는 순서대로.
    var screenshots: [UUID]
    var developers: [String]?
    /// 예: `1.2.0 (34)`. 아직 출시본이 없으면 nil.
    var latestRelease: String?
    var downloadCount: Int?
    var rating: RatingSummary?
    var shareURL: String?

    init(_ app: AppDTO) {
        self.id = app.id
        self.bundleID = app.bundleID
        self.bundleIDPending = app.bundleIDPending == true ? true : nil
        self.name = app.name
        self.summary = app.summary
        self.description = app.description
        self.category = app.category
        self.tags = app.tags ?? []
        // 주소의 마지막 조각이 id 다 (`APIPath.appScreenshot`).
        self.screenshots = (app.screenshotURLs ?? []).compactMap {
            $0.split(separator: "/").last.flatMap { UUID(uuidString: String($0)) }
        }
        self.developers = app.developerNames
        self.latestRelease = app.latestReleasedVersion.map { "\($0.shortVersion) (\($0.buildNumber))" }
        self.downloadCount = app.downloadCount
        self.rating = app.rating
        self.shareURL = app.shareURL
    }
}

/// `add_screenshots` 의 결과. 중간에 멈췄으면 무엇이 남았고 왜인지가 함께 온다.
struct ScreenshotUpload: Encodable {
    var added: [String]
    var notAdded: [String]?
    var reason: String?
    var app: AppDetails?
}

/// `save_screenshots` 의 결과. 중간에 멈췄으면 받지 못한 id 와 이유가 함께 온다.
struct SavedScreenshots: Encodable {
    var files: [String]
    var notSaved: [UUID]?
    var reason: String?
}

/// 한 장도 올리지 못했다. 서버가 한 말을 그대로 전한다.
struct ScreenshotUploadError: Error, CustomStringConvertible {
    var reason: String
    var description: String { reason }
}

/// 한 세션 동안의 앱 목록.
///
/// 도구들이 앱을 id 나 번들 ID 로 받는데, 그때마다 목록을 다시 받아오면 한
/// 세션에 같은 응답을 여러 번 받는다. 그 응답에는 아이콘 주소와 별점까지 들어 있다.
actor AppDirectory {
    static let shared = AppDirectory()

    private var cached: [AppDTO]?

    func apps(using api: StoreAPI) async throws -> [AppDTO] {
        if let cached { return cached }
        let fetched = try await api.apps()
        cached = fetched
        return fetched
    }

    /// 들고 있던 것을 버리고 새로 받는다.
    func reload(using api: StoreAPI) async throws -> [AppDTO] {
        cached = nil
        return try await apps(using: api)
    }
}
