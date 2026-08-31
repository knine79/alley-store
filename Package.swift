// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Alley",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AlleyShared", targets: ["AlleyShared"]),
        .executable(name: "alley-server", targets: ["AlleyServer"]),
        .executable(name: "alley-worker", targets: ["AlleyWorker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.106.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.4.0"),
        .package(url: "https://github.com/vapor/jwt.git", from: "5.0.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        // 서명 결과물의 SHA-256 을 계산한다. Vapor 가 이미 끌어오지만, 워커는 Vapor 를
        // 쓰지 않으므로 직접 선언한다.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // DTO와 API 경로 정의. 서버·워커·스토어 앱이 공유한다.
        // 의존성을 두지 않아 SwiftUI 앱에서도 그대로 임포트할 수 있어야 한다.
        .target(name: "AlleyShared"),

        .executableTarget(
            name: "AlleyServer",
            dependencies: [
                "AlleyShared",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "SotoS3", package: "soto"),
            ]
        ),

        // 워커의 실제 동작. 실행 파일과 나눠둔 이유는 테스트 때문이다. 실행 타깃은
        // main.swift 를 들고 있어서 테스트 타깃이 그대로 임포트하기 곤란하다.
        .target(
            name: "AlleyWorkerCore",
            dependencies: [
                "AlleyShared",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),

        .executableTarget(
            name: "AlleyWorker",
            dependencies: ["AlleyWorkerCore"]
        ),

        .testTarget(name: "AlleySharedTests", dependencies: ["AlleyShared"]),
        .testTarget(name: "AlleyWorkerTests", dependencies: ["AlleyWorkerCore"]),
        .testTarget(
            name: "AlleyServerTests",
            dependencies: [
                "AlleyServer",
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)
