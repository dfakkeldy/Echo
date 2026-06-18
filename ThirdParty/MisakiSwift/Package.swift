// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Vendored from mlalma/MisakiSwift @ 6835a1c (Apache-2.0), with local changes
// for Echo:
//   1. Resources are NOT declared here. Upstream's `.copy("../../Resources/")`
//      produces a `MisakiSwift_MisakiSwift.bundle` whose `.bundle` extension
//      the iOS-simulator codesign rejects ("bundle format unrecognized").
//      Instead the model/lexicon files (us_*.json, us_*.safetensors) ship as
//      Echo app-bundle resources under `MisakiResources/`, and the 4 load sites
//      read them via `Bundle.main` (see DataResourcesUtil.swift and
//      EnglishFallbackNetwork.swift). This signs cleanly on sim, device, macOS.
//   2. British-English (`gb_*`) resources removed — Echo ships US English only.

import PackageDescription

let package = Package(
  name: "MisakiSwift",
  platforms: [
    .iOS(.v18), .macOS(.v15)
  ],
  products: [
    .library(
      name: "MisakiSwift",
      type: .dynamic,
      targets: ["MisakiSwift"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
  ],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
     ]
    ),
    .testTarget(
      name: "MisakiSwiftTests",
      dependencies: ["MisakiSwift"]
    ),
  ]
)
