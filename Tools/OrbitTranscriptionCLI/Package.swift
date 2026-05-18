// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitTranscriptionCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.7.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .executableTarget(
            name: "OrbitTranscriptionCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "OrbitEPUBAligner"),
            ]
        ),
        .target(
            name: "OrbitEPUBAligner",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "OrbitTranscriptionCLITests",
            dependencies: ["OrbitTranscriptionCLI"]
        ),
        .testTarget(
            name: "OrbitEPUBAlignerTests",
            dependencies: ["OrbitEPUBAligner"]
        ),
    ]
)
