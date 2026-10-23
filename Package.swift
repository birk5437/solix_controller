// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SOLIXController",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SOLIXController", targets: ["SOLIXController"]),
    ],
    targets: [
        .target(
            name: "SOLIXCore",
            path: "Sources/SOLIXCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "SOLIXController",
            dependencies: ["SOLIXCore"],
            path: "Sources/SOLIXController"
        ),
        .testTarget(
            name: "SOLIXCoreTests",
            dependencies: ["SOLIXCore"],
            path: "Tests/SOLIXCoreTests"
        ),
    ]
)
