# Phonon 31M narration

Phonon is an optional English narrator alongside Kokoro. Choose a voice in a
**Phonon 31M** section of the narration picker, or in Mac **Settings → Playback →
Narration Voice**. Existing selections keep using Kokoro.

The voices are Hadley, Harper, Preston, Easton, Maeve, and Spencer. The first
selection downloads Gradium's 137 MB Core ML bundle (release 0.7.1) and compiles its models for
the device. Later runs reuse the local cache. Text stays on the device.

Phonon supplies 24 kHz mono audio and measured paragraph alignment. It does not
consume Kokoro's IPA annotations or supply Kokoro's exact word timings. Echo does
not publish Kokoro pronunciation audit receipts for a Phonon or mixed-engine
export. Use Kokoro when those features matter.

Its text planner keeps complete sentences together up to 200 words per request,
splitting unusually long sentences at whitespace. Phonon blocks bypass Kokoro's
phoneme budgets and pronunciation preflight; mixed plans retain the source order
and the existing heading, paragraph, and section pauses.

## Command line

Build with `make echo-cli` through the usual build wrapper, then select a voice:

```sh
echo-cli narrate --epub book.epub --out book-phonon.m4b \
  --sidecar book-phonon.alignment.json --work-dir phonon-work \
  --title "Book" --author "Author" --voice ph31m_v040_preston
```

Use a separate work directory and output for a comparison with an existing
Kokoro render. The `ph31m_v040_` voice prefix is historical and stays fixed so
saved selections and voice plans survive upgrades; the renderer identity
(`echo.phonon-31m-en.coreml.<release>`) carries the runtime version, so an
upgrade never reuses earlier Phonon audio from a synthesis cache. Headless
capture identities also record the engine family.

Phonon samples its audio. Echo sets a fixed seed before every request, so the
same text and voice give the same audio on every render. Per-chapter and block
voice plans use the same voice IDs, including plans mixing the two engines.

## Runtime and assets

- Swift package: [`gradium-ai/xn-ptts`](https://github.com/gradium-ai/xn-ptts),
  exact version **0.7.1**, product `ptts`, module `PhononTTS`.
- Models: `phonon-31m-en-coreml.zip` from the same release, authenticated by
  SHA-256 `058cde756a5e67bcdb986e7c45fe431d41a1a9073e68aabae314c80631a34b76`.
  Release 0.7.0 re-exported it with a 200-token prefill, matching Echo's
  200-word requests, so long sentences no longer end early.
- Echo authenticates the bundle manifest and every original model/voice file
  before loading. Downloads are staged before publication into Echo's cache.
- A developer can set `ECHO_PHONON_MODEL_DIR` to an extracted bundle. The same
  verification applies; the override does not bypass integrity checks.
- The released native runtime is arm64-only: iOS 18+, macOS 15+ on Apple Silicon,
  and arm64 iOS simulators. Watch and widget targets do not link the runtime;
  Watch and CarPlay play the resulting audio through their existing paths.

The model is Apache-2.0; the runtime is MIT OR Apache-2.0. See
[third-party notices](../THIRD_PARTY_NOTICES.md).
