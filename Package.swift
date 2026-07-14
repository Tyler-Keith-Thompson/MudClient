// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MudClient",
    platforms: [.macOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .executable(name: "MudClient", targets: ["MudClient"]),
        .library(name: "ScriptDescription",
                 type: .dynamic,
                 targets: ["ScriptDescription"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/Tyler-Keith-Thompson/Afluent.git", from: "0.6.2"),
        .package(url: "git@github.com:Tyler-Keith-Thompson/DependencyInjection.git", from: "0.0.7"),
        .package(path: "../swift-parsing"),
        .package(url: "git@github.com:JohnSundell/ShellOut.git", from: "2.3.0"),
        .package(url: "https://github.com/Kolos65/Mockable.git", from: "0.6.4"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        // Embedded Lua 5.4 C library (vendored under Sources/CLua). Replaces the
        // old swift-build + dlopen scripting pipeline.
        .target(
            name: "CLua",
            cSettings: [
                .define("LUA_USE_MACOSX"),
            ]
        ),
        .executableTarget(
            name: "MudClient",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Afluent", package: "Afluent"),
                .product(name: "DependencyInjection", package: "DependencyInjection"),
                .product(name: "Parsing", package: "swift-parsing"),
                .product(name: "ShellOut", package: "ShellOut"),
                .product(name: "Mockable", package: "Mockable"),
                "ScriptDescription",
                "CLua",
            ],
            // Mockable's generated mocks are gated behind the MOCKING compile condition, so they
            // exist in debug (tests) but are stripped from release builds. Bazel mirrors this by
            // defining MOCKING only on the test-facing MudClientLib target.
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug)),
            ]
        ),
        .target(name: "ScriptDescription",
                dependencies: [
                    .product(name: "Afluent", package: "Afluent"),
                    .product(name: "Parsing", package: "swift-parsing"),
                    .product(name: "DependencyInjection", package: "DependencyInjection"),
                ]),
        .testTarget(
            name: "MudClientTests",
            dependencies: [
                "MudClient",
                .product(name: "Mockable", package: "Mockable"),
            ]
        ),
    ]
)
