// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "banti",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "BantiCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/BantiCore",
            linkerSettings: [
                .linkedFramework("SoundAnalysis"),
            ]
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
