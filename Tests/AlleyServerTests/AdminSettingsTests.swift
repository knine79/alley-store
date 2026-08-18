import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

@Suite("스토어 설정 관리")
struct AdminSettingsTests {
    private let settingsPath = "\(APIPath.adminRoot)/settings"

    @Test("관리자만 설정을 읽을 수 있다")
    func onlyAdminReadsSettings() async throws {
        try await withMigratedApp { app in
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (_, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (_, userToken) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .GET, settingsPath, headers: .bearer(adminToken)
            ) { #expect($0.status == .ok) }

            // 번들 ID 정책이나 허용 도메인은 밖에 알릴 이유가 없다.
            for token in [devToken, userToken] {
                try await app.testing().test(
                    .GET, settingsPath, headers: .bearer(token)
                ) { #expect($0.status == .forbidden) }
            }
            try await app.testing().test(.GET, settingsPath) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    @Test("바꾼 설정이 다음 요청부터 반영된다")
    func updatedSettingsTakeEffect() async throws {
        try await withMigratedApp(overrides: ["STORE_NAME": "Example Store"]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        UpdateStoreSettingsRequest(storeName: "Renamed Store", accentColor: "#112233")
                    )
                }
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(StoreSettingsDTO.self)
                #expect(dto.storeName == "Renamed Store")
            }

            // 재기동 없이 곧바로 반영돼야 한다. 그러지 않으면 화면에서 바꾼 뒤
            // "언제 적용되나요"를 매번 묻게 된다.
            try await app.testing().test(.GET, APIPath.meta) { response in
                let meta = try response.content.decode(StoreMeta.self)
                #expect(meta.storeName == "Renamed Store")
                #expect(meta.accentColor == "#112233")
            }
        }
    }

    @Test("보낸 항목만 바꾸고 나머지는 건드리지 않는다")
    func patchLeavesOmittedFieldsAlone() async throws {
        try await withMigratedApp(overrides: [
            "STORE_NAME": "Example Store",
            "ALLOWED_EMAIL_DOMAINS": "example.com",
            "BUNDLE_ID_PREFIX": "com.example",
        ]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "Renamed Store"))
                }
            ) { response in
                let dto = try response.content.decode(StoreSettingsDTO.self)
                #expect(dto.storeName == "Renamed Store")
                // 이름만 고쳤는데 도메인 정책이 날아가면 로그인이 열린다.
                #expect(dto.allowedEmailDomains == ["example.com"])
                #expect(dto.bundleIDPrefix == "com.example")
            }
        }
    }

    @Test("확인 없이 허용 도메인을 비울 수 없다")
    func emptyingDomainsNeedsConfirmation() async throws {
        try await withMigratedApp(overrides: ["ALLOWED_EMAIL_DOMAINS": "example.com"]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 목록이 비면 조직 밖 계정도 전부 로그인한다.
            // 오타 한 번으로 그렇게 되는 것을 막는다.
            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        UpdateStoreSettingsRequest(allowedEmailDomains: [])
                    )
                }
            ) { #expect($0.status == .badRequest) }

            try await app.testing().test(.GET, settingsPath, headers: .bearer(token)) { response in
                let dto = try response.content.decode(StoreSettingsDTO.self)
                #expect(dto.allowedEmailDomains == ["example.com"], "거부된 요청이 값을 바꾸면 안 된다")
            }
        }
    }

    @Test("확인을 붙이면 허용 도메인을 비울 수 있다")
    func confirmedEmptyingIsAllowed() async throws {
        try await withMigratedApp(overrides: ["ALLOWED_EMAIL_DOMAINS": "example.com"]) { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        UpdateStoreSettingsRequest(
                            allowedEmailDomains: [],
                            confirmOpenToAnyDomain: true
                        )
                    )
                }
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(StoreSettingsDTO.self)
                #expect(dto.allowedEmailDomains.isEmpty)
            }
        }
    }

    @Test("도메인을 소문자로 맞추고 중복과 공백을 걸러낸다")
    func normalizesDomains() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(
                        UpdateStoreSettingsRequest(
                            allowedEmailDomains: [" Example.COM ", "example.com", "", "other.example"]
                        )
                    )
                }
            ) { response in
                let dto = try response.content.decode(StoreSettingsDTO.self)
                // 넣은 순서는 유지한다. 화면에서 순서가 뒤집히면 헷갈린다.
                #expect(dto.allowedEmailDomains == ["example.com", "other.example"])
            }
        }
    }

    @Test("스토어 이름은 비울 수 없다")
    func storeNameCannotBeEmptied() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "   "))
                }
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("바꾼 사람이 기록된다")
    func recordsWhoChangedIt() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, settingsPath, headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateStoreSettingsRequest(storeName: "Renamed Store"))
                }
            ) { #expect($0.status == .ok) }

            let stored = try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            #expect(stored?.$updatedBy.id == (try admin.requireID()))
        }
    }
}

@Suite("사용자 역할 관리")
struct AdminUserRoleTests {
    private func rolePath(_ id: UUID) -> String { "\(APIPath.adminRoot)/users/\(id.uuidString)" }

    @Test("관리자가 역할을 올릴 수 있다")
    func adminPromotesUser() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, _) = try await app.makeUser(email: "user@example.com", role: .user)

            try await app.testing().test(
                .PATCH, rolePath(try target.requireID()), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateUserRoleRequest(role: .developer))
                }
            ) { response in
                #expect(response.status == .ok)
                let dto = try response.content.decode(UserDTO.self)
                #expect(dto.role == .developer)
            }
        }
    }

    @Test("관리자가 아니면 역할을 못 바꾼다")
    func nonAdminCannotChangeRoles() async throws {
        try await withMigratedApp { app in
            let (_, devToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (target, _) = try await app.makeUser(email: "user@example.com", role: .user)

            // 스스로 개발자에서 관리자로 올라갈 수 있으면 역할 구분이 무의미하다.
            try await app.testing().test(
                .PATCH, rolePath(try target.requireID()), headers: .bearer(devToken),
                beforeRequest: { request in
                    try request.content.encode(UpdateUserRoleRequest(role: .admin))
                }
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("마지막 관리자는 강등할 수 없다")
    func lastAdminCannotBeDemoted() async throws {
        try await withMigratedApp { app in
            let (admin, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 강등되면 아무도 설정을 못 바꾸는 상태가 된다. 되돌릴 방법은 서버 재배포뿐이다.
            try await app.testing().test(
                .PATCH, rolePath(try admin.requireID()), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateUserRoleRequest(role: .user))
                }
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("다른 관리자가 있으면 강등할 수 있다")
    func demotionAllowedWhenAnotherAdminRemains() async throws {
        try await withMigratedApp { app in
            let (first, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            _ = try await app.makeUser(email: "admin2@example.com", role: .admin)

            try await app.testing().test(
                .PATCH, rolePath(try first.requireID()), headers: .bearer(token),
                beforeRequest: { request in
                    try request.content.encode(UpdateUserRoleRequest(role: .user))
                }
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("역할 변경이 다음 요청부터 바로 먹는다")
    func roleChangeAppliesImmediately() async throws {
        try await withMigratedApp { app in
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (target, targetToken) = try await app.makeUser(email: "user@example.com", role: .user)

            // 세션 토큰에 역할을 담지 않는 이유가 이것이다 (ADR-0008).
            try await app.testing().test(.GET, APIPath.apps, headers: .bearer(targetToken)) { _ in }

            try await app.testing().test(
                .PATCH, rolePath(try target.requireID()), headers: .bearer(adminToken),
                beforeRequest: { request in
                    try request.content.encode(UpdateUserRoleRequest(role: .developer))
                }
            ) { #expect($0.status == .ok) }

            // 토큰은 그대로인데 권한이 올라가 있어야 한다.
            try await app.testing().test(
                .POST, APIPath.apps, headers: .bearer(targetToken),
                beforeRequest: { request in
                    try request.content.encode(
                        CreateAppRequest(bundleID: "com.example.newapp", name: "새 앱")
                    )
                }
            ) { #expect($0.status == .created) }
        }
    }
}
