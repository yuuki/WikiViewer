// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WikiKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "WikiShared", targets: ["WikiShared"]),
        .library(name: "WikiViewerKit", targets: ["WikiViewerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
    ],
    targets: [
        // Pure Swift, no dependencies: Obsidian syntax scanning, link targets,
        // manifest model, schema constants. Shared by the indexer and the app.
        .target(name: "WikiShared"),
        // Read-only viewer data layer, generation management, transport,
        // Markdown presentation. Used by the iOS app.
        .target(
            name: "WikiViewerKit",
            dependencies: [
                "WikiShared",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
                // LaTeX typesetting for $…$ and $$…$$ (the apps only, see MathRenderer).
                .product(name: "SwiftMath", package: "SwiftMath", condition: .when(platforms: [.iOS, .macOS])),
            ],
            resources: [.copy("Resources/DemoArtifact")]
        ),
        .testTarget(name: "WikiSharedTests", dependencies: ["WikiShared"]),
        .testTarget(name: "WikiViewerKitTests", dependencies: ["WikiViewerKit"]),
    ],
    swiftLanguageModes: [.v6]
)
