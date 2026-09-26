// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let defaultSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .unsafeFlags(["-Osize"], .when(configuration: .release)),
]

let apiSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .unsafeFlags(["-O"], .when(configuration: .release)),
]

let package = Package(
    name: "appitool",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "appitool", targets: ["appitool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.6.0"),
        .package(url: "https://github.com/onevcat/Rainbow.git", from: "4.2.2"),
    ],
    targets: [
        // Apple App Store Connect API (library target with generator plugin)
        .target(
            name: "AppStoreConnectAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Google Play Android Developer API (OpenAPI generator plugin target)
        .target(
            name: "GooglePlayStoreAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Google Play Developer Reporting API (OpenAPI generator plugin target)
        .target(
            name: "GooglePlayReportingAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Google Play Games Services Publishing API (OpenAPI generator plugin target)
        .target(
            name: "GooglePlayGamesConfigurationAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Google Play Integrity API (OpenAPI generator plugin target)
        .target(
            name: "GooglePlayIntegrityAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Google Play Custom App Publishing API (OpenAPI generator plugin target)
        .target(
            name: "GooglePlayCustomAppAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        // Google Play Games Services Management API (OpenAPI generator plugin target)
        .target(
            name: "GooglePlayGamesManagementAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),

        .executableTarget(
            name: "appitool",
            dependencies: [
                "AppStoreConnectAPI",
                "GooglePlayStoreAPI",
                "GooglePlayReportingAPI",
                "GooglePlayGamesConfigurationAPI",
                "GooglePlayIntegrityAPI",
                "GooglePlayCustomAppAPI",
                "GooglePlayGamesManagementAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "Rainbow", package: "Rainbow"),
            ],
            swiftSettings: defaultSwiftSettings,
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip", "-Xlinker", "-s"], .when(configuration: .release)),
            ]
        ),

        .testTarget(
            name: "appitoolTests",
            dependencies: ["appitool"],
//            swiftSettings: defaultSwiftSettings
        ),
    ]
)
