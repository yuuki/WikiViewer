// swift-tools-version: 6.2
import PackageDescription

// Host-side (macOS) indexer and artifact publisher for WikiViewer.
// Reads an Obsidian vault strictly read-only and publishes immutable
// viewer database generations plus content-addressed assets.
let package = Package(
    name: "WikiIndexer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "wikiindex", targets: ["wikiindex"]),
        .library(name: "IndexerCore", targets: ["IndexerCore"]),
    ],
    dependencies: [
        .package(path: "../WikiKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(
            name: "IndexerCore",
            dependencies: [
                .product(name: "WikiShared", package: "WikiKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "wikiindex",
            dependencies: [
                "IndexerCore",
                // Only for `bench-queries`, which runs the viewer's query layer on the host.
                .product(name: "WikiViewerKit", package: "WikiKit"),
            ]
        ),
        .testTarget(
            name: "IndexerCoreTests",
            dependencies: [
                "IndexerCore",
                .product(name: "WikiViewerKit", package: "WikiKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
