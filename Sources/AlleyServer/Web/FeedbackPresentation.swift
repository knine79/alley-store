import AlleyShared
import Fluent
import Foundation
import Vapor

/// 피드백을 화면용 자료로 옮긴다.
///
/// JSON API 와 화면이 같은 규칙(누구 이름을 보여줄지, 누가 지울 수 있는지)을 쓰되
/// 모양이 다르다. 화면은 별을 문자열로 미리 받고 날짜도 사람이 읽는 형태여야 한다.
enum FeedbackPresentation {
    static func rows(
        ofApp appID: UUID,
        viewer: User,
        on request: Request
    ) async throws -> [FeedbackRow] {
        let app = try await App.find(appID, on: request.db)
        let canManage = try app.map { try $0.canManage(viewer) } ?? false
        let viewerID = try viewer.requireID()

        let entries = try await Feedback.query(on: request.db)
            .filter(\.$app.$id == appID)
            .with(\.$user)
            .with(\.$version)
            .sort(\.$createdAt, .descending)
            .all()

        var rows: [FeedbackRow] = []
        for entry in entries {
            var screenshotURL: String?
            if let key = entry.screenshotKey {
                screenshotURL = try? await request.artifactStorage.downloadURL(key: key).url
            }

            let isMine = entry.$user.id == viewerID
            rows.append(
                FeedbackRow(
                    id: try entry.requireID().uuidString,
                    versionName: "\(entry.version.shortVersion) (\(entry.version.buildNumber))",
                    rating: entry.rating,
                    stars: entry.rating.map { String(repeating: "★", count: $0) },
                    body: entry.body,
                    screenshotURL: screenshotURL,
                    // 익명은 화면에서만 익명이다. 오너에게도 이름을 보여주지 않는다.
                    authorName: entry.isAnonymous ? nil : entry.user.name,
                    isAnonymous: entry.isAnonymous,
                    isMine: isMine,
                    createdAt: DateStyle.minute.string(from: entry.createdAt ?? Date()),
                    canDelete: isMine || canManage
                )
            )
        }
        return rows
    }

    /// 이 사람이 피드백을 남길 수 있는 버전들.
    ///
    /// 받아본 출시본만 나온다. 남길 곳이 없으면 화면이 폼을 띄우지 않는다. 누를 수
    /// 없는 폼을 보여주고 "받아본 버전에만 남길 수 있습니다"로 거절하는 것보다 낫다.
    static func reviewableVersions(
        ofApp appID: UUID,
        viewer: User,
        on database: any Database
    ) async throws -> [ReviewableVersion] {
        let viewerID = try viewer.requireID()

        let downloaded = try await Download.query(on: database)
            .filter(\.$user.$id == viewerID)
            .all()
            .map(\.$version.id)
        guard !downloaded.isEmpty else { return [] }

        return try await Version.query(on: database)
            .filter(\.$app.$id == appID)
            .filter(\.$id ~~ downloaded)
            .filter(\.$state == .released)
            .sort(\.$buildNumber, .descending)
            .all()
            .map { version in
                ReviewableVersion(
                    id: try version.requireID().uuidString,
                    name: "\(version.shortVersion) (\(version.buildNumber))"
                )
            }
    }
}
