// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Vendored from mlalma/MisakiSwift @ 6835a1c (Apache-2.0), with local changes
// for Echo:
//   1. Resources are NOT declared here. Upstream's `.copy("../../Resources/")`
//      produces a `MisakiSwift_MisakiSwift.bundle` whose `.bundle` extension
//      the iOS-simulator codesign rejects ("bundle format unrecognized").
//      Instead the US-English model/lexicon files (us_gold, us_silver) ship as
//      Echo app-bundle resources under
//      `EchoCore/Services/Narration/MisakiResources/`, and the load sites read
//      them via `Bundle.main`. This signs cleanly on sim, device, macOS.
//   2. British-English (`gb_*`) resources removed — Echo ships US English only.
//   3. The MLX-backed BART OOV-fallback network was removed (lexicon-only G2P),
//      and MLXUtilsLibrary (which transitively pulled mlx-swift) was dropped.
//      mlx-swift is no longer a dependency — it had an upstream iOS-Simulator
//      link bug (ml-explore/mlx-swift#341) that blocked the whole sim test
//      suite, and the BART fallback's value on Echo's nonfiction workload was
//      low. OOV words now emit the ❓ unk glyph; user pronunciation overrides
//      (PronunciationOverrides) are the supported way to give OOV words a real
//      pronunciation. The one MLXUtilsLibrary symbol MisakiSwift actually used
//      (MToken) is now vendored at Sources/MisakiSwift/DataStructures/MToken.swift
//      (148 lines, Foundation+NaturalLanguage only — Apache-2.0, mlalma/MLXUtilsLibrary).

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
  dependencies: [],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: []
    ),
    .testTarget(
      name: "MisakiSwiftTests",
      dependencies: ["MisakiSwift"]
    ),
  ]
)
