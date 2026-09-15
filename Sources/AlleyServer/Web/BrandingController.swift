import AlleyShared
import Fluent
import Foundation
import Vapor

/// 브랜딩 이미지를 내주는 자리.
///
/// **로그인을 걸지 않는다.** 파비콘은 로그인 화면의 탭에 뜨고, 앱 아이콘은 스토어
/// 앱이 아직 로그인하기 전에 받아간다. 관리자가 "이걸 우리 얼굴로 쓰겠다" 고 올린
/// 그림이라 감출 것도 없다.
struct BrandingController: RouteCollection, Sendable {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("branding", ":asset", use: serve)
    }

    @Sendable
    func serve(request: Request) async throws -> Response {
        guard let name = request.parameters.get("asset"),
              let kind = Self.kind(forFileName: name)
        else {
            throw Abort(.notFound)
        }
        guard let asset = try await BrandingAssetService.find(kind: kind, on: request.db) else {
            // 안 올린 것과 없는 주소는 다르지만, 브라우저에게는 둘 다 "그림이 없다" 다.
            throw Abort(.notFound)
        }

        // 키에 UUID 가 들어 있어 내용이 바뀌면 키도 바뀐다. 그래서 키 자체가
        // 그대로 ETag 가 된다. 따로 해시를 뜨지 않아도 된다.
        let etag = "\"\(asset.storageKey)\""
        if request.headers.first(name: .ifNoneMatch) == etag {
            let response = Response(status: .notModified)
            Self.applyCacheHeaders(to: response, etag: etag)
            return response
        }

        let data = try await request.application.storedImages.data(forKey: asset.storageKey) {
            try await request.application.artifactStorage.get(
                key: asset.storageKey,
                limit: BrandingAssetService.maximumUploadSize
            )
        }

        let response = Response(status: .ok)
        response.headers.contentType = HTTPMediaType(type: "image", subType: "png")
        Self.applyCacheHeaders(to: response, etag: etag)
        response.body = .init(data: data)
        return response
    }

    /// `favicon.png` 같은 파일 이름을 종류로 바꾼다.
    ///
    /// 경로에 확장자를 두는 이유는 브라우저가 파비콘을 다룰 때 그것을 보기 때문이다.
    /// 확장자 없는 주소를 파비콘으로 주면 무시하는 브라우저가 있다.
    static func kind(forFileName name: String) -> BrandingAssetKind? {
        guard name.hasSuffix(".png") else { return nil }
        return BrandingAssetKind(rawValue: String(name.dropLast(4)))
    }

    /// 60초만 들고 있게 한다.
    ///
    /// 화면의 링크에는 `?v=` 가 붙어 있어서 바꾼 그림은 바로 보인다. 이 값은 그
    /// 표시가 없는 주소 - 스토어 앱이 받아가는 앱 아이콘, 브라우저가 스스로 찾는
    /// `/favicon.ico` 대체 - 를 위한 것이다. 길게 잡으면 로고를 바꿨는데 하루 동안
    /// 옛것이 보이고, 짧게 잡아도 ETag 덕에 오가는 것은 헤더뿐이다.
    private static func applyCacheHeaders(to response: Response, etag: String) {
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=60")
    }
}
