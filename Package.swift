// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "banti",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BantiCore",
            path: "Sources/BantiCore"
        ),
        .executableTarget(
            name: "banti",
            dependencies: ["BantiCore"],
            path: "Sources/banti"
        ),
        .testTarget(
            name: "BantiTests",
            dependencies: ["BantiCore"],
            path: "Tests/BantiTests"
        ),
    ]
)
