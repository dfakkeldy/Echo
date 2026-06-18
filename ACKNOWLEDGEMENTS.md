# Acknowledgements

Echo builds on the work of many open-source projects.

## Third-party libraries

| Library | License | Purpose |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | SQLite-backed persistence for audiobook metadata, EPUB blocks, alignment anchors. |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT | EPUB (`.epub` = ZIP) archive reading. |
| [WhisperKit](https://github.com/argumetainspires/WhisperKit) | MIT | On-device speech recognition for chapter auto-alignment. |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 | Streamed Kokoro TTS inference (legacy narration engine; retained for one-line revert). |
| [swift-audio-marker](https://github.com/atelier-socle/swift-audio-marker) | MIT | Audio timestamp markers. |
| [KokoroPipeline](https://github.com/mattmireles/kokoro-coreml) (`ThirdParty/KokoroPipeline/`) | Apache-2.0 | Fixed-shape CoreML Kokoro TTS pipeline (duration → F0Ntrain → hn-NSF harmonic source → GeneratorFromHar) — the wedge-free narration engine. Vendored locally from the `swift/` subdirectory. |
| [MisakiSwift](https://github.com/mlalma/MisakiSwift) (`ThirdParty/MisakiSwift/`) | Apache-2.0 | English G2P phonemizer (grapheme → IPA) for Kokoro narration — **lexicon-only** (the MLX-backed BART OOV-fallback network was removed to drop the mlx-swift dependency). Vendored locally: British-English resources removed (US only); US lexicon resources relocated into the Echo app bundle to work around an SPM `.bundle` iOS-simulator codesign rejection; the `MToken` data structure (from `mlalma/MLXUtilsLibrary`, Apache-2.0) vendored in-module at `Sources/MisakiSwift/DataStructures/MToken.swift`. OOV words emit the ❓ unk glyph and are silent — user pronunciation overrides are the supported fix. |
| [MLXUtilsLibrary](https://github.com/mlalma/MLXUtilsLibrary) (`MToken.swift` only) | Apache-2.0 | The `MToken` token data structure, vendored in-module into MisakiSwift. (The rest of MLXUtilsLibrary and its mlx-swift dependency are not used.) |

## Model weights

- **Kokoro-82M** (`af_heart` / "Ava" voice pack, CoreML fixed-shape buckets) — © hexgrad, Apache-2.0. Downloaded at first use from `huggingface.co/mattmireles/kokoro-coreml`.
