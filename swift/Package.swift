// swift-tools-version: 6.0
import PackageDescription

// This package exists solely to declare MudClient's external SwiftPM
// dependencies for rules_swift_package_manager. The first-party targets
// (MudClient, ScriptDescription) are built by hand-written BUILD.bazel files
// that reference the @swiftpkg_* repos generated from this manifest.
//
// The local `swift-parsing` fork is intentionally NOT listed here — it is built
// directly from source via //third_party:swift_parsing.BUILD.
let package = Package(
    name: "MudClientDependencies",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/Tyler-Keith-Thompson/Afluent.git", from: "0.6.2"),
        .package(url: "https://github.com/Tyler-Keith-Thompson/DependencyInjection.git", from: "0.0.7"),
        .package(url: "https://github.com/JohnSundell/ShellOut.git", from: "2.3.0"),
        .package(url: "https://github.com/Kolos65/Mockable.git", from: "0.6.4"),
    ]
)
