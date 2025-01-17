// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "DiscordBM",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "DiscordBM",
            targets: ["DiscordBM"]
        ),
        .library(
            name: "DiscordCore",
            targets: ["DiscordCore"]
        ),
        .library(
            name: "DiscordHTTP",
            targets: ["DiscordHTTP"]
        ),
        .library(
            name: "DiscordGateway",
            targets: ["DiscordGateway"]
        ),
        .library(
            name: "DiscordModels",
            targets: ["DiscordModels"]
        ),
        .library(
            name: "DiscordUtilities",
            targets: ["DiscordUtilities"]
        ),
        .library(
            name: "DiscordAuth",
            targets: ["DiscordAuth"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.49.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.2"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.15.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.5.3"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.5"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.23.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.15.0"),
    ],
    targets: [
        .target(
            name: "DiscordBM",
            dependencies: [
                "DiscordAuth",
                "DiscordHTTP",
                "DiscordCore",
                "DiscordGateway",
                "DiscordModels",
                "DiscordUtilities",
            ]
        ),
        .target(
            name: "DiscordCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MultipartKit", package: "multipart-kit"),
            ]
        ),
        .target(
            name: "DiscordHTTP",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                "DiscordModels",
            ]
        ),
        .target(
            name: "DiscordGateway",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                "DiscordWebSocket",
                "DiscordHTTP",
            ]
        ),
        .target(
            name: "DiscordModels",
            dependencies: [
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "MultipartKit", package: "multipart-kit"),
                "DiscordCore"
            ]
        ),
        .target(
            name: "DiscordUtilities",
            dependencies: [
                "DiscordModels"
            ]
        ),
        .target(
            name: "DiscordAuth",
            dependencies: [
                "DiscordModels"
            ]
        ),
        .plugin(
            name: "GenerateAPIEndpoints",
            capability: .command(
                intent: .custom(
                    verb: "generate-api-endpoints",
                    description: "Generates API Endpoints"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Add Generated Endpoints")
                ]
            ),
            dependencies: ["GenerateAPIEndpointsExec"]
        ),
        .executableTarget(
            name: "GenerateAPIEndpointsExec",
            dependencies: [
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Plugins/GenerateAPIEndpointsExec",
            resources: [.copy("Resources/openapi.yml")]
        ),
        /// Vapor's `WebSocketKit` with modifications to fit `DiscordBM` better.
        .target(
            name: "DiscordWebSocket",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Atomics", package: "swift-atomics"),
                "CZlib"
            ]
        ),
        .target(
            name: "CZlib",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "DiscordBMTests",
            dependencies: ["DiscordBM"]
        ),
        /// Vapor's `WebSocketKit` tests with modifications to fit `DiscordBM` better.
        .testTarget(
            name: "WebSocketTests",
            dependencies: ["DiscordWebSocket"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["DiscordBM"]
        ),
    ]
)
