import AlleyShared
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import AlleyServer

/// 스토어 앱만 dmg 로도 나간다 (ADR-0050).
///
/// **워커는 이 잡이 무엇인지 모른다.** 그 성질을 지키려고 "무엇인가" 가 아니라
/// "무엇을 해라" 를 잡에 싣는다. 여기서 보는 것은 그 지시가 스토어 앱 빌드에만
/// 붙는지, 그리고 붙은 결과가 받는 자리까지 이어지는지다.
@Suite("스토어 앱 dmg")
struct StoreAppDiskImageTests {
    /// 서버가 스토어 앱을 빌드해 큐에 넣으면 dmg 지시가 함께 간다.
    @Test("스토어 앱 빌드는 dmg 를 요구한다")
    func storeAppBuildRequestsADiskImage() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (_, version) = try await StoreAppBootstrapTests.makeStoreApp(on: app, owner: admin)

            let job = try #require(
                try await SigningJob.query(on: app.db)
                    .filter(\.$version.$id == version.requireID())
                    .first()
            )
            #expect(job.makesDiskImage)
        }
    }

    /// **다른 앱에는 붙지 않는다.** 스토어 앱이 받아서 `/Applications` 에 직접 넣으므로
    /// 사람이 옮길 일이 없다. 만들어봐야 아무도 안 쓰는 파일이 앱마다 쌓인다.
    @Test("보통 앱 업로드는 dmg 를 요구하지 않는다")
    func ordinaryUploadsDoNotRequestADiskImage() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "owner@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: "com.example.other", name: "다른 앱", owner: owner
            )
            let version = try await app.seedVersion(
                appID: try record.requireID(), short: "1.0.0", build: 1, state: .uploaded, by: owner
            )

            let job = try await SigningJob.enqueue(
                versionID: try version.requireID(), on: app.db
            )
            #expect(!job.makesDiskImage)
        }
    }

    /// 지시서에 자리가 있어야 워커가 만든다. 없으면 지금까지처럼 zip 만 만든다.
    @Test("dmg 를 요구한 잡의 지시서에만 올릴 자리가 있다")
    func onlyDiskImageJobsCarryAnUploadSlot() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            // 출시까지 밀지 않는다. 잡은 서명을 기다리는 동안에만 워커에게 나간다.
            _ = try await StoreAppBootstrapTests.makeStoreApp(
                on: app, owner: admin, released: false
            )
            let (_, workerToken) = try await app.makeWorker()

            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(workerToken)
            ) { response in
                #expect(response.status == .ok)
                let ticket = try response.content.decode(SigningJobDTO.self)
                let url = try #require(ticket.diskImageUploadURL)
                // 확장자가 갈래를 따라간다. dmg 를 `.zip` 으로 올려두면 받는 쪽이
                // zip 으로 알고 풀려 들다가 실패한다.
                #expect(url.contains("dmg.dmg"))
            }
        }
    }

    /// **dmg 가 있으면 그것을 먼저 준다.** 받은 사람이 열면 Applications 별칭이 함께
    /// 보여서 옮기는 일이 드래그 한 번으로 끝난다.
    @Test("받는 자리는 dmg 를 먼저 내준다")
    func publicPagePrefersTheDiskImage() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (storeApp, version) = try await StoreAppPublicPageTests.makeSignedStoreApp(
                on: app, owner: admin
            )

            // 아직 dmg 가 없으면 zip 이 나간다.
            #expect(StoreAppGetController.downloadable(version)?.kind == .signed)
            #expect(
                StoreAppGetController.downloadFilename(app: storeApp, version: version)
                    .hasSuffix(".zip")
            )

            let key = "apps/test/\(try version.requireID().uuidString)/dmg.dmg"
            try await app.artifactStorage.put(
                Data("dmg 라고 치자".utf8), to: key, contentType: "application/x-apple-diskimage"
            )
            try await Artifact(
                versionID: try version.requireID(),
                kind: .diskImage,
                storageKey: key,
                sha256: nil,
                fileSize: 24
            ).save(on: app.db)
            try await version.$artifacts.load(on: app.db)

            #expect(StoreAppGetController.downloadable(version)?.kind == .diskImage)
            #expect(
                StoreAppGetController.downloadFilename(app: storeApp, version: version)
                    == "\(storeApp.name) \(version.shortVersion).dmg"
            )

            try await app.testing().test(.GET, "/get/download") { response in
                #expect(response.status == .seeOther)
                let location = try #require(response.headers.first(name: .location))
                #expect(location.contains("dmg.dmg"))
            }
        }
    }

    /// **dmg 가 없다고 잡을 실패시키지 않는다.** zip 은 이미 올라와서 배포가 되고,
    /// dmg 를 모르는 예전 워커까지 실패로 떨어뜨릴 이유가 없다.
    @Test("예전 워커가 dmg 없이 끝내도 배포는 된다")
    func oldWorkersWithoutDiskImageStillSucceed() async throws {
        try await withMigratedApp { app in
            let (admin, _) = try await app.makeUser(email: "admin@example.com", role: .admin)
            let (_, version) = try await StoreAppBootstrapTests.makeStoreApp(
                on: app, owner: admin, released: false
            )
            let (_, workerToken) = try await app.makeWorker()

            var jobID: UUID?
            try await app.testing().test(
                .GET, "\(APIPath.nextJob)?timeout=0", headers: .bearer(workerToken)
            ) { response in
                jobID = try response.content.decode(SigningJobDTO.self).id
            }
            let id = try #require(jobID)

            // 서명본은 올라온 것으로 해둔다. 서버가 스토리지에서 확인한다.
            let signedKey = ArtifactStorage.objectKey(
                appID: version.$app.id, versionID: try version.requireID(), kind: .signed
            )
            try await app.artifactStorage.put(
                Data("서명된 zip".utf8), to: signedKey, contentType: "application/zip"
            )

            // dmg 값 없이 보고한다. 이 필드를 모르는 예전 워커가 보내는 모양이다.
            try await app.testing().test(
                .PATCH, APIPath.job(id),
                headers: .bearer(workerToken),
                beforeRequest: { request in
                    try request.content.encode(
                        SigningJobUpdate(state: .succeeded, resultSize: 12)
                    )
                }
            ) { response in
                #expect(response.status == .noContent)
            }

            let refreshed = try #require(try await Version.find(try version.requireID(), on: app.db))
            #expect(refreshed.state == .ready)

            let artifacts = try await Artifact.query(on: app.db)
                .filter(\.$version.$id == version.requireID())
                .all()
            #expect(artifacts.contains { $0.kind == .signed })
            #expect(!artifacts.contains { $0.kind == .diskImage })
        }
    }
}
