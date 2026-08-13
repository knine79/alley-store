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

        .executableTarget(
            name: "AlleyWorker",
            dependencies: ["AlleyShared"]
        ),

        .testTarget(name: "AlleySharedTests", dependencies: ["AlleyShared"]),
        .testTarget(
            name: "AlleyServerTests",
            dependencies: [
                "AlleyServer",
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)
