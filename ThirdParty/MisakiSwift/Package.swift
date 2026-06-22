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
//      low. OOV words are now voiced by a deterministic, vocab-safe grapheme→IPA
//      approximator (EnglishFallbackNetwork) so they are never silently dropped;
//      EnglishG2P additionally enforces a never-voiceless guarantee on final
//      assembly. User pronunciation overrides (PronunciationOverrides) remain the
//      way to give an OOV word a precise pronunciation. The one MLXUtilsLibrary
//      symbol MisakiSwift actually used
//      (MToken) is now vendored at Sources/MisakiSwift/DataStructures/MToken.swift
//      (148 lines, Foundation+NaturalLanguage only — Apache-2.0, mlalma/MLXUtilsLibrary).

import PackageDescription

let package = Package(
    name: "MisakiSwift",
    platforms: [
        .iOS(.v18), .macOS(.v15),
    ],
    products: [
        .library(
            // Static (default), matching the sibling KokoroPipeline package. It was
            // `.dynamic` only to coexist with mlx-swift; MLX was dropped (see note 3
            // above) so a separate dynamic framework is no longer needed — and under
            // the app's hardened runtime an ad-hoc-signed, non-embedded MisakiSwift
            // .framework has no Team ID, so dyld refused to load it and the signed
            // macOS/device app aborted at launch ("different Team IDs"). Linking the
            // (dependency-free, resource-free) sources straight into the app avoids
            // the embed-and-re-sign dance entirely.
            name: "MisakiSwift",
            targets: ["MisakiSwift"]
        )
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
