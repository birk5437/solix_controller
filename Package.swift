// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnkerController",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AnkerController", targets: ["AnkerController"]),
    ],
    targets: [
        .target(
            name: "AnkerCore",
            path: "Sources/AnkerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AnkerController",
            dependencies: ["AnkerCore"],
            path: "Sources/AnkerController"
        ),
        .testTarget(
            name: "AnkerCoreTests",
            dependencies: ["AnkerCore"],
            path: "Tests/AnkerCoreTests"
        ),
    ]
)
