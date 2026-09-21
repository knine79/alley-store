import AlleyShared
import Fluent
import Testing
import VaporTesting

@testable import AlleyServer

/// 출시된 버전 하나와 그것을 받아본 사람.
private struct FeedbackSetup {
    var owner: User
    var ownerToken: String
    var reader: User
    var readerToken: String
    var appID: UUID
    var versionID: UUID
}

private func seedReleasedVersion(
    on app: Application,
    downloadedByReader: Bool = true
) async throws -> FeedbackSetup {
    let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
    let (reader, readerToken) = try await app.makeUser(
        email: "user@example.com", role: .user, name: "받은 사람"
    )
    let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
    let appID = try record.requireID()
    let version = try await app.seedVersion(
        appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
    )
    let versionID = try version.requireID()

    if downloadedByReader {
        try await Download(userID: try reader.requireID(), versionID: versionID)
            .save(on: app.db)
    }

    return FeedbackSetup(
        owner: owner,
        ownerToken: ownerToken,
        reader: reader,
        readerToken: readerToken,
        appID: appID,
        versionID: versionID
    )
}

private func feedbackPath(_ versionID: UUID) -> String {
    "\(APIPath.apiRoot)/versions/\(versionID.uuidString)/feedback"
}

@Suite("피드백 남기기")
struct SubmitFeedbackTests {
    @Test("받아본 버전에 별점과 글을 남긴다")
    func submitsRatingAndBody() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 4, body: "검색이 빨라졌습니다.")
                    )
                }
            ) { response in
                #expect(response.status == .created)
                let dto = try response.content.decode(FeedbackDTO.self)
                #expect(dto.rating == 4)
                #expect(dto.author?.email == "user@example.com")
                #expect(dto.isMine)
            }
        }
    }

    @Test("받아본 적 없으면 남길 수 없다")
    func requiresDownload() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app, downloadedByReader: false)

            // 안 써본 앱에 별점을 주는 것은 정보가 아니다.
            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(rating: 1))
                }
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("별점도 글도 없으면 거절한다")
    func requiresContent() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(body: "   "))
                }
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("별점 범위를 벗어나면 거절한다", arguments: [0, 6, -1])
    func rejectsOutOfRange(_ rating: Int) async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(rating: rating))
                }
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("출시 전 버전에는 남길 수 없다")
    func requiresReleasedVersion() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            let draft = try await app.seedVersion(
                appID: setup.appID, short: "1.1.0", build: 2, state: .ready, by: setup.owner
            )
            let draftID = try draft.requireID()
            try await Download(userID: try setup.reader.requireID(), versionID: draftID)
                .save(on: app.db)

            try await app.testing().test(
                .POST, feedbackPath(draftID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(rating: 5))
                }
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test("같은 버전에 두 번 남기면 앞의 것을 고친다")
    func secondSubmissionEdits() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            for rating in [2, 5] {
                try await app.testing().test(
                    .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                    beforeRequest: { request in
                        try request.content.encode(SubmitFeedbackRequest(rating: rating))
                    }
                ) { #expect($0.status == .created) }
            }

            // 사람 하나가 같은 빌드에 대해 두 번 말할 이유가 없다.
            let entries = try await Feedback.query(on: app.db).all()
            #expect(entries.count == 1)
            #expect(entries.first?.rating == 5)
        }
    }
}

@Suite("피드백 익명")
struct AnonymousFeedbackTests {
    @Test("익명으로 남기면 화면에 이름이 없다")
    func hidesAuthorWhenAnonymous() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 2, body: "느립니다.", isAnonymous: true)
                    )
                }
            ) { response in
                let dto = try response.content.decode(FeedbackDTO.self)
                #expect(dto.author == nil)
                #expect(dto.isAnonymous)
            }

            // 오너가 봐도 이름이 없다.
            try await app.testing().test(
                .GET, "\(APIPath.apiRoot)/apps/\(setup.appID.uuidString)/feedback",
                headers: .bearer(setup.ownerToken)
            ) { response in
                let list = try response.content.decode([FeedbackDTO].self)
                #expect(list.first?.author == nil)
            }
        }
    }

    @Test("익명이어도 서버는 누가 남겼는지 안다")
    func serverStillKnowsAuthor() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 2, isAnonymous: true)
                    )
                }
            ) { #expect($0.status == .created) }

            // 본인이 고치고 지울 수 있어야 하고, 악용이 생기면 추적할 수 있어야 한다.
            let entry = try #require(try await Feedback.query(on: app.db).first())
            #expect(entry.$user.id == (try setup.reader.requireID()))
        }
    }

    @Test("익명으로 남겨도 본인에게는 자기 것으로 보인다")
    func ownerOfAnonymousSeesItAsMine() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 3, isAnonymous: true)
                    )
                }
            ) { #expect($0.status == .created) }

            try await app.testing().test(
                .GET, "\(APIPath.apiRoot)/apps/\(setup.appID.uuidString)/feedback",
                headers: .bearer(setup.readerToken)
            ) { response in
                let list = try response.content.decode([FeedbackDTO].self)
                #expect(list.first?.isMine == true)
            }
        }
    }
}

@Suite("피드백 지우기")
struct RemoveFeedbackTests {
    private func submit(on app: Application, setup: FeedbackSetup) async throws -> UUID {
        var id: UUID?
        try await app.testing().test(
            .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
            beforeRequest: { request in
                try request.content.encode(SubmitFeedbackRequest(rating: 3))
            }
        ) { id = try $0.content.decode(FeedbackDTO.self).id }
        return try #require(id)
    }

    @Test("내가 남긴 것을 지운다")
    func removesOwn() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            let id = try await submit(on: app, setup: setup)

            try await app.testing().test(
                .DELETE, "\(APIPath.apiRoot)/feedback/\(id.uuidString)",
                headers: .bearer(setup.readerToken)
            ) { #expect($0.status == .noContent) }

            #expect(try await Feedback.query(on: app.db).count() == 0)
        }
    }

    @Test("앱 오너도 지울 수 있다")
    func ownerCanRemove() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            let id = try await submit(on: app, setup: setup)

            // 도를 넘은 글을 관리자를 부를 때까지 두는 것보다 앱을 맡은 사람이 내리는 편이 낫다.
            try await app.testing().test(
                .DELETE, "\(APIPath.apiRoot)/feedback/\(id.uuidString)",
                headers: .bearer(setup.ownerToken)
            ) { #expect($0.status == .noContent) }
        }
    }

    @Test("남이 남긴 것은 지울 수 없다")
    func strangersCannotRemove() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            let id = try await submit(on: app, setup: setup)
            let (_, otherToken) = try await app.makeUser(email: "other@example.com", role: .user)

            try await app.testing().test(
                .DELETE, "\(APIPath.apiRoot)/feedback/\(id.uuidString)",
                headers: .bearer(otherToken)
            ) { #expect($0.status == .forbidden) }
        }
    }
}

@Suite("별점 집계")
struct RatingSummaryTests {
    @Test("평균과 개수를 센다")
    func computesAverage() {
        let summary = Feedback.summary(of: [5, 4, 3])
        #expect(summary.count == 3)
        #expect(summary.average == 4)
        #expect(summary.displayAverage == "4.0")
    }

    @Test("한 자리로 반올림한다")
    func roundsToOneDecimal() {
        // 3.25 를 "3.3" 으로 보여준다. 화면에 소수점이 길게 나오면 읽기 나쁘다.
        #expect(Feedback.summary(of: [3, 3, 3, 4]).displayAverage == "3.3")
    }

    @Test("아무도 안 남겼으면 평균이 없다")
    func handlesEmpty() {
        let summary = Feedback.summary(of: [])
        #expect(summary.count == 0)
        #expect(summary.average == nil)
        #expect(summary.displayAverage == nil)
    }

    @Test("앱 목록에 별점이 실린다")
    func listCarriesRating() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(rating: 4))
                }
            ) { #expect($0.status == .created) }

            try await app.testing().test(
                .GET, APIPath.apps, headers: .bearer(setup.readerToken)
            ) { response in
                let apps = try response.content.decode([AppDTO].self)
                #expect(apps.first?.rating?.count == 1)
                #expect(apps.first?.rating?.average == 4)
            }
        }
    }

    @Test("글만 남긴 것은 별점으로 세지 않는다")
    func bodyOnlyIsNotRated() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(body: "버그가 있습니다."))
                }
            ) { #expect($0.status == .created) }

            let summary = try await Feedback.summary(ofApp: setup.appID, on: app.db)
            #expect(summary.count == 0)
        }
    }
}

@Suite("피드백 화면")
struct FeedbackPageTests {
    /// **웹 콘솔에는 남기는 자리가 없다.** 피드백은 앱을 실제로 받아 쓴 사람이
    /// 스토어 앱에서 남기는 값인데, 웹 콘솔에 오는 사람은 대개 올리는 쪽이다.
    /// 화면 하나에 남기는 칸과 읽는 칸이 같이 있으면 그 구분이 흐려진다.
    @Test("웹 콘솔에는 남기는 폼도 경로도 없다")
    func consoleHasNoSubmitPath() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            let path = "/apps/\(setup.appID.uuidString)"

            try await app.testing().test(
                .GET, path, headers: .sessionCookie(setup.readerToken)
            ) { response in
                let html = response.body.string
                #expect(!html.contains("남기기"))
                #expect(html.contains("피드백은 스토어 앱에서 받습니다"))
            }

            // 화면에서 걷어내는 것만으로는 부족하다. 경로 자체가 없어야 한다.
            try await app.testing().test(
                .POST, "\(path)/feedback",
                headers: .form(cookie: setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        ["versionID": setup.versionID.uuidString, "rating": "5"],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .notFound) }
        }
    }

    /// 남기는 길은 스토어 앱이 쓰는 API 다. 그 길로 들어온 것이 화면에 뜨는지 본다.
    @Test("앱에서 남기면 콘솔 목록에 뜬다")
    func showsFeedbackFromApp() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, "/api/v1/versions/\(setup.versionID.uuidString)/feedback",
                headers: .form(cookie: setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 5, body: "빠릅니다.", isAnonymous: false)
                    )
                }
            ) { #expect($0.status == .created) }

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)",
                headers: .sessionCookie(setup.readerToken)
            ) { response in
                let html = response.body.string
                #expect(html.contains("빠릅니다."))
                #expect(html.contains("받은 사람"))
                // 평균이 제목 옆에 붙는다.
                #expect(html.contains("5.0"))
            }
        }
    }

    @Test("익명으로 남기면 화면에 이름이 없다")
    func consoleHidesAnonymousAuthor() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, "/api/v1/versions/\(setup.versionID.uuidString)/feedback",
                headers: .form(cookie: setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(body: "느립니다.", isAnonymous: true)
                    )
                }
            ) { #expect($0.status == .created) }

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)",
                headers: .sessionCookie(setup.ownerToken)
            ) { response in
                let html = response.body.string
                #expect(html.contains("느립니다."))
                #expect(!html.contains("받은 사람"))
                #expect(html.contains("익명"))
            }
        }
    }

    @Test("알림 대상은 관리하는 사람에게만 보인다")
    func notificationSectionIsForManagers() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)",
                headers: .sessionCookie(setup.readerToken)
            ) { #expect(!$0.body.string.contains("대상 추가")) }

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)",
                headers: .sessionCookie(setup.ownerToken)
            ) { #expect($0.body.string.contains("대상 추가")) }
        }
    }

    @Test("화면에서 알림 대상을 붙인다")
    func addsTargetFromConsole() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)

            try await app.testing().test(
                .POST, "/apps/\(setup.appID.uuidString)/notification-targets",
                headers: .form(cookie: setup.ownerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        [
                            "name": "팀 채널",
                            "endpoint": "https://hooks.slack.com/services/T/B/x",
                        ],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)",
                headers: .sessionCookie(setup.ownerToken)
            ) { response in
                #expect(response.body.string.contains("팀 채널"))
                // 주소 자체는 다시 보이지 않는다. 폼의 placeholder 와 헷갈리지 않도록
                // 우리가 넣은 경로 조각으로 확인한다.
                #expect(!response.body.string.contains("/services/T/B/x"))
            }
        }
    }
}

@Suite("익명 허용 설정")
struct AnonymousPolicyTests {
    @Test("기본은 익명을 받는다")
    func allowsByDefault() async throws {
        try await withMigratedApp { app in
            let settings = try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            // 이미 도는 스토어의 동작이 갑자기 바뀌지 않아야 한다.
            #expect(settings?.allowsAnonymousFeedback != false)
        }
    }

    @Test("끄면 익명 요청을 거절한다")
    func rejectsAnonymousWhenDisabled() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            let settings = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )
            settings.allowsAnonymousFeedback = false
            try await settings.save(on: app.db)

            // 조용히 실명으로 바꾸지 않는다. 익명인 줄 알고 쓴 글에 이름이 붙는 것이
            // 이 기능에서 가장 나쁜 실패다.
            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 3, isAnonymous: true)
                    )
                }
            ) { #expect($0.status == .forbidden) }

            // 실명 피드백은 그대로 받는다.
            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(SubmitFeedbackRequest(rating: 3))
                }
            ) { #expect($0.status == .created) }
        }
    }

    @Test("꺼도 이미 익명으로 남긴 글은 익명으로 남는다")
    func keepsExistingAnonymity() async throws {
        try await withMigratedApp { app in
            let setup = try await seedReleasedVersion(on: app)
            try await app.testing().test(
                .POST, feedbackPath(setup.versionID), headers: .bearer(setup.readerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SubmitFeedbackRequest(rating: 2, body: "느립니다", isAnonymous: true)
                    )
                }
            ) { #expect($0.status == .created) }

            let settings = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )
            settings.allowsAnonymousFeedback = false
            try await settings.save(on: app.db)

            // 남길 때의 약속을 나중에 뒤집으면 그 사람이 쓴 것이 다른 뜻이 된다.
            try await app.testing().test(
                .GET, "/apps/\(setup.appID.uuidString)",
                headers: .sessionCookie(setup.ownerToken)
            ) { response in
                #expect(response.body.string.contains("느립니다"))
                #expect(!response.body.string.contains("받은 사람"))
            }
        }
    }

    /// **이 설정이 화면에 닿는 곳은 스토어 앱뿐이다.** 웹 콘솔에는 남기는 폼이
    /// 없어서(위 `consoleHasNoSubmitPath`) 체크박스를 띄울 자리도 없다. 그래서
    /// 여기서 확인할 것은 앱이 읽어가는 값이 설정을 따라 바뀌는가다.
    @Test("스토어 앱이 볼 수 있게 meta 에 실린다")
    func metaCarriesPolicy() async throws {
        try await withMigratedApp { app in
            try await app.testing().test(.GET, APIPath.meta) { response in
                let meta = try response.content.decode(StoreMeta.self)
                #expect(meta.allowsAnonymousFeedback)
            }

            let settings = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )
            settings.allowsAnonymousFeedback = false
            try await settings.save(on: app.db)

            try await app.testing().test(.GET, APIPath.meta) { response in
                let meta = try response.content.decode(StoreMeta.self)
                #expect(!meta.allowsAnonymousFeedback)
            }
        }
    }

    @Test("관리자 화면에서 끈다")
    func adminTurnsItOff() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            // 체크박스를 빼고 보내면 껐다는 뜻이다.
            try await app.testing().test(
                .POST, "/admin/settings", headers: .form(cookie: token),
                beforeRequest: { request in
                    try request.content.encode(
                        ["storeName": "Example Store", "allowedEmailDomains": "example.com"],
                        as: .urlEncodedForm
                    )
                }
            ) { #expect($0.status == .seeOther) }

            let stored = try #require(
                try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            )
            #expect(!stored.allowsAnonymousFeedback)
        }
    }
}
