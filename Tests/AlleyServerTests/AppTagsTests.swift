import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 앱에 검색용 태그를 붙인다 (이슈 #43).
@Suite("앱 태그")
struct AppTagsTests {
    @Test("API 로 태그를 붙이면 다듬어서 저장하고 내려준다")
    func updatesThroughAPI() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            let appID = try seeded.requireID()
            #expect(seeded.tags.isEmpty)

            try await app.testing().test(
                .PATCH, APIPath.app(appID), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateAppRequest(tags: [" 번역 ", "Git", "git", ""]))
                }
            ) { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(AppDTO.self)
                #expect(body.tags == ["번역", "Git"])
            }

            let stored = try #require(try await App.find(appID, on: app.db))
            #expect(stored.tags == ["번역", "Git"])
        }
    }

    @Test("규칙을 넘으면 거절하고 그대로 둔다")
    func rejectsOverLimit() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            let appID = try seeded.requireID()
            let tooMany = (1...AppTags.maximumCount + 1).map { "태그\($0)" }

            try await app.testing().test(
                .PATCH, APIPath.app(appID), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateAppRequest(tags: tooMany))
                }
            ) { #expect($0.status == .badRequest) }

            let stored = try #require(try await App.find(appID, on: app.db))
            #expect(stored.tags.isEmpty)
        }
    }

    @Test("콘솔의 앱 정보 고치기에서 쉼표로 적은 태그를 저장한다")
    func updatesThroughConsole() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            let appID = try seeded.requireID()

            // 앱 상세에는 고치는 화면으로 가는 버튼만 있다.
            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                #expect(response.body.string.contains(#"href="/apps/\#(appID.uuidString)/edit""#))
            }

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/edit", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        ["name": "메모장", "summary": "", "description": "", "category": "",
                         "tags": "일정, 번역 ,일정"],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(try await App.find(appID, on: app.db))
            #expect(stored.tags == ["일정", "번역"])

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)/edit", headers: .sessionCookie(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("일정, 번역"))
            }
        }
    }

    @Test("규칙을 넘는 태그는 고치는 화면에서 적은 것을 둔 채 알려준다")
    func consoleShowsErrorInPlace() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            let appID = try seeded.requireID()
            let tooLong = String(repeating: "가", count: AppTags.maximumLength + 1)

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/edit", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        ["name": "메모장", "summary": "적어둔 소개", "tags": tooLong],
                        as: .urlEncodedForm
                    )
                }
            ) { response in
                #expect(response.status == .badRequest)
                let html = response.body.string
                #expect(html.contains("notice-error"))
                #expect(html.contains("적어둔 소개"))
            }
        }
    }

    @Test("손댈 수 없는 사람은 고치는 화면을 열지 못한다")
    func editFormRequiresManageAccess() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, otherToken) = try await app.makeUser(email: "other@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)

            try await app.testing().test(
                .GET, "/apps/\(try seeded.requireID().uuidString)/edit", headers: .sessionCookie(otherToken)
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("태그를 보내지 않은 수정은 태그를 건드리지 않는다")
    func keepsTagsWhenOmitted() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            seeded.tags = ["번역"]
            try await seeded.save(on: app.db)

            try await app.testing().test(
                .PATCH, APIPath.app(try seeded.requireID()), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateAppRequest(summary: "번역기"))
                }
            ) { #expect($0.status == .ok) }

            let stored = try #require(try await App.find(try seeded.requireID(), on: app.db))
            #expect(stored.tags == ["번역"])
        }
    }
}
