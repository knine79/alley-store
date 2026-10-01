import AlleyShared
import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@testable import AlleyServer

/// 분류를 코드에 정한 목록에서 고른다 (이슈 #44).
@Suite("앱 분류 저장")
struct AppCategoryStorageTests {
    @Test("정해진 분류는 저장 값으로, 화면 이름도 받는다")
    func acceptsKnownCategories() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            let appID = try seeded.requireID()

            for (sent, stored) in [("design", "design"), ("개발 도구", "developer-tools")] {
                try await app.testing().test(
                    .PATCH, APIPath.app(appID), headers: .bearer(token),
                    beforeRequest: { try $0.content.encode(UpdateAppRequest(category: sent)) }
                ) { #expect($0.status == .ok) }
                #expect(try await App.find(appID, on: app.db)?.category == stored)
            }

            // 비우면 미분류다.
            try await app.testing().test(
                .PATCH, APIPath.app(appID), headers: .bearer(token),
                beforeRequest: { try $0.content.encode(UpdateAppRequest(category: "")) }
            ) { #expect($0.status == .ok) }
            #expect(try await App.find(appID, on: app.db)?.category == nil)
        }
    }

    @Test("목록에 없는 분류는 거절한다")
    func rejectsUnknown() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)

            try await app.testing().test(
                .PATCH, APIPath.app(try seeded.requireID()), headers: .bearer(token),
                beforeRequest: { try $0.content.encode(UpdateAppRequest(category: "게임")) }
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("콘솔 앱 상세가 분류를 고르는 칸을 보여주고, 고른 것을 저장한다")
    func consoleSelect() async throws {
        try await withMigratedApp { app in
            let (owner, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let seeded = try await app.seedApp(bundleID: "com.example.notes", name: "메모장", owner: owner)
            let appID = try seeded.requireID()

            try await app.testing().test(
                .POST, "/apps/\(appID.uuidString)/edit", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        ["name": "메모장", "category": "productivity", "tags": ""],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            try await app.testing().test(
                .GET, "/apps/\(appID.uuidString)", headers: .sessionCookie(token)
            ) { response in
                let html = response.body.string
                #expect(html.contains(#"<option value="productivity" selected>생산성</option>"#))
                #expect(html.contains(#"<span class="badge">생산성</span>"#))
            }
        }
    }

    @Test("마이그레이션은 화면 이름으로 적힌 값만 옮기고 모르는 값은 남긴다")
    func migrationMapsTitles() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let known = try await app.seedApp(bundleID: "com.example.a", name: "가", owner: owner)
            let unknown = try await app.seedApp(bundleID: "com.example.b", name: "나", owner: owner)
            known.category = "개발 도구"
            unknown.category = "사내 도구"
            try await known.save(on: app.db)
            try await unknown.save(on: app.db)

            try await NormalizeAppCategories().prepare(on: app.db)

            #expect(try await App.find(known.requireID(), on: app.db)?.category == "developer-tools")
            #expect(try await App.find(unknown.requireID(), on: app.db)?.category == "사내 도구")
        }
    }
}
