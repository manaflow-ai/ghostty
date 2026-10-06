// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-vt-xcframework",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "swift-vt-xcframework",
            dependencies: ["GhosttyVt"],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyVt",
            path: "../../zig-out/lib/ghostty-vt.xcframework"
        ),
    ]
)
