// swift-tools-version: 6.0
import PackageDescription

// TideCore holds everything in Tide that is not UI: text indexing, tokenizing,
// fuzzy matching, themes, workspace search, the built-in shell and diagnostics.
// It depends only on Foundation, so `swift test` runs on a Mac host without a
// simulator.
let package = Package(
    name: "TideCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TideCore", targets: ["TideCore"]),
    ],
    targets: [
        .target(name: "TideCore"),
        .testTarget(name: "TideCoreTests", dependencies: ["TideCore"]),
    ]
)
