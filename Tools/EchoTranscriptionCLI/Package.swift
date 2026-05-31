// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EchoTranscriptionCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.7.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .executableTarget(
            name: "EchoTranscriptionCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "EchoEPUBAligner"),
            ]
        ),
        .target(
            name: "EchoEPUBAligner",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "EchoTranscriptionCLITests",
            dependencies: ["EchoTranscriptionCLI"]
        ),
        .testTarget(
            name: "EchoEPUBAlignerTests",
            dependencies: ["EchoEPUBAligner"]
        ),
    ]
)
