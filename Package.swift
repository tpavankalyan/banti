// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "banti",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "banti",
            path: "Sources/banti"
        ),
        .testTarget(
            name: "BantiTests",
            dependencies: ["banti"],
            path: "Tests/BantiTests"
        ),
    ]
)
