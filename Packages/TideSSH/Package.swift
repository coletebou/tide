// swift-tools-version: 6.0
import PackageDescription

// TideSSH is Tide's SSH client: terminal sessions over SwiftNIO SSH, OpenSSH
// key import, and known_hosts checking. It sits on Apple's swift-nio-ssh
// rather than a wrapper library (docs/reports/SSH client choice.md has why),
// so the SSH protocol core gets Apple's security fixes and Tide owns only a
// thin client layer. Its tests run on a Mac host against a real OpenSSH
// server that scripts/ssh-test-server.sh starts.
let package = Package(
    name: "TideSSH",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TideSSH", targets: ["TideSSH"]),
    ],
    dependencies: [
        .package(path: "../TideCore"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .target(
            name: "TideSSH",
            dependencies: [
                .product(name: "TideCore", package: "TideCore"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "TideSSHTests",
            dependencies: ["TideSSH", .product(name: "TideCore", package: "TideCore")]
        ),
    ]
)
