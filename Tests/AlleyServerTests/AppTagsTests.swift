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

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                #expect(response.body.string.contains("앱 정보 고치기"))
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
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                #expect(response.body.string.contains("일정, 번역"))
            }
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
