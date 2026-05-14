// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitTranscriptionCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.7.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "OrbitTranscriptionCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "OrbitTranscriptionCLITests",
            dependencies: ["OrbitTranscriptionCLI"]
        ),
    ]
)
