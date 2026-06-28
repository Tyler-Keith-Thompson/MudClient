"""Build file injected into the local swift-parsing fork checkout.

Builds only the `Parsing` library target. MudClient does not use the
`#if CasePaths` features, so the CasePaths trait is left disabled and there is
no swift-case-paths / swift-syntax dependency. The copts mirror the
`swiftSettings` the package's Package.swift applies to every target.
"""

load("@rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "Parsing",
    srcs = glob(["Sources/Parsing/**/*.swift"]),
    copts = [
        "-swift-version",
        "5",
        "-enable-upcoming-feature",
        "ExistentialAny",
        "-enable-upcoming-feature",
        "ImmutableWeakCaptures",
        "-enable-upcoming-feature",
        "InferIsolatedConformances",
        "-enable-upcoming-feature",
        "InternalImportsByDefault",
        "-enable-upcoming-feature",
        "MemberImportVisibility",
        "-enable-upcoming-feature",
        "NonisolatedNonsendingByDefault",
    ],
    module_name = "Parsing",
    visibility = ["//visibility:public"],
)
