// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift Package Manager required to build this package.
//
// Vendored from mattmireles/kokoro-coreml (`swift/`).
// Only the `KokoroPipeline` library product + its tests are exposed to Echo;
// the upstream `kokoro-bench` / `kokoro-hnsf-bench` executable targets are
// intentionally NOT built by the app (they are dev-only CLIs).

import PackageDescription

let package = Package(
    name: "KokoroPipeline",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "KokoroPipeline", targets: ["KokoroPipeline"]),
    ],
    targets: [
        .target(
            name: "KokoroPipeline",
            path: "Sources/KokoroPipeline"
        ),
        .testTarget(
            name: "KokoroPipelineTests",
            dependencies: ["KokoroPipeline"],
            path: "Tests/KokoroPipelineTests"
        ),
    ]
)
