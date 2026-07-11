# Planned Pronunciation TTS Render QA - 2026-07-11

Status: automated Release render gate passed; human listening pending.

## Provenance

- Branch: `codex/pronunciation-planned-tts-slice`
- Render source commit: `9d52706fc4fc552f117bedec886bf7a65f77ccef`
- External run directory:
  `/Users/dfakkeldy/Developer/echo-overnight/pronunciation-regression-20260711/`
- Source PDF SHA-256:
  `172d652c80176d1db51d49e7abdb41aee0603cd35bd587dd5664eadfc8736512`
- Release CLI: `.build/cli/Build/Products/Release/echo-cli`
- CLI identity: `ONNX rv11 (Release)`, universal `arm64` + `x86_64`
- CLI SHA-256:
  `1d376245d505c5628be512a59c1727f07053bcb06c469d0bff62b313651d63a1`
- Cached model:
  `~/Library/Application Support/Narration/Models/kokoro-onnx-v6/model_fp16.onnx`
- Model size: 163,234,740 bytes
- Model SHA-256:
  `ba4527a874b42b21e35f468c10d326fdff3c7fc8cac1f85e9eb6c0dfc35c334a`

Both renders were fresh, used `env -u ECHO_RESOURCE_DIR`, `--jobs 1`, and
`--threads 2`, and did not use `--resume`. The generated raw chapter cache names
carry narration cache version `v11`.

## Corpus and approved planning matrix

The selectable PDF contains one page and one target paragraph per case. Echo's
production PDF importer exported 24 blocks: 12 synthetic `Page N` headings plus
the following 12 paragraphs.

| # | Source | Expected planning behavior |
|---:|---|---|
| 1 | The process is startable today. | `[startable](/stˈɑɹɾəbᵊl/)` |
| 2 | The filesystem stores the verified result. | `[filesystem](/fˈIl sˌɪstəm/)`; `verified` remains ordinary lexicon |
| 3 | The result was verified by the reviewer. | ordinary lexicon `vˈɛɹəfˌId`, no override link or fallback |
| 4 | They live nearby. | verb `[live](/lˈɪv/)` |
| 5 | It was a live show. | adjective `[live](/lˈIv/)` |
| 6 | She lives in Halifax. | verb `[lives](/lˈɪvz/)` |
| 7 | The receipt lives in the archive. | verb/metaphor `[lives](/lˈɪvz/)` |
| 8 | Their lives changed. | plural noun `[lives](/lˈIvz/)` |
| 9 | Please record the result. | verb `[record](/ɹəkˈɔɹd/)` |
| 10 | Review the record before restart. | noun `[record](/ɹˈɛkəɹd/)` |
| 11 | Record sales increased. | noun modifier `[Record](/ɹˈɛkəɹd/)` |
| 12 | Should record labels pay artists? | noun modifier `[record](/ɹˈɛkəɹd/)` |

Automated assertions cover the exact compatibility links, `verified`'s ordinary
lexicon/no-fallback path, strict BOS/EOS-wrapped phoneme ID validation, planned
protocol dispatch, and equality of waveform and duration-head IDs. The native
ONNX integration also ran against the cached real model. The Release CLI does
not log raw planned phoneme ID arrays; the plan-to-waveform claim is therefore
the tested code boundary coupled to the hashed `rv11` binary, not an acoustic
transcript claim.

## Native Release renders

```text
env -u ECHO_RESOURCE_DIR "$CLI" narrate \
  --epub "$SOURCE_PDF" --out "$RUN/$VOICE.m4b" \
  --sidecar "$RUN/$VOICE-sidecar.json" --voice "$VOICE" \
  --title "Echo Pronunciation Regression" --author "Echo QA" \
  --work-dir "$RUN/work-$VOICE" --db "$RUN/$VOICE.sqlite" \
  --jobs 1 --threads 2
```

| Voice | Result | M4B SHA-256 | Duration / format |
|---|---|---|---|
| `am_michael` | 12 chapters, 63 s audio, 41 s wall | `ebaf7b47e7dc65d498fb1d8637418af6a735e29beed856da747c189fed982d7b` | 63.488 s, AAC, 24 kHz mono |
| `af_heart` | 12 chapters, 59 s audio, 36 s wall | `86ea9f2b2f423b3c7113bcc7091a5be3e75050ee9e9136a391e761f5f3be9296` | 58.880 s, AAC, 24 kHz mono |

Echo's `verify-sidecar` passed both outputs:

```text
SIDECAR_OK .../am_michael-sidecar.json - 24 anchors, 12 chapters, 23 anchors with verified word timings
SIDECAR_OK .../af_heart-sidecar.json - 24 anchors, 12 chapters, 23 anchors with verified word timings
```

The sole anchor without word timings is `s1-b1`, the `filesystem` paragraph.
That is the intended safe interpolation behavior when a multiword IPA link's
phoneme-space groups do not match its one display word.

## Media integrity and listening clips

The external delivery contains 50 checked audio files: two M4Bs, 24 lossless raw
ALAC chapters, and 24 heading-free AAC listening clips. `ffprobe`, `afinfo`,
`silencedetect=noise=-50dB:d=0.5`, and `volumedetect` were run over the artifacts.

- All 50 files decoded, had exactly one audio stream, and passed the non-silence
  threshold.
- Minimum duration: 2.050 s.
- Quietest maximum level: -8.3 dBFS.
- Largest fraction made of silence events at least 500 ms: 0.552. This includes
  Echo's deliberate block/chapter pauses.
- Full M4B maximum levels: -1.2 dBFS (`am_michael`) and -2.6 dBFS (`af_heart`).
- Representative raw `filesystem` chapters are 24 kHz mono ALAC with SHA-256:
  - `am_michael`: `9e6dcfea9406dd753ca647263b84c172775ddfee1ec3cdbd835fc4b22e7209d9`
  - `af_heart`: `974e5c8eee7f1c1cbc4c828d1523b44c077c7e3f2d06b2a91dc36baa51e7f846`

The complete metrics and checksum manifest are external:

- `media-metrics.json`
- `media-summary.json`
- `afinfo.txt`
- `checksums.sha256` (50 entries, `shasum -a 256 -c` exit 0)
- `clips/index.json`

Each voice has 12 directly playable clips under `clips/<voice>/`, named from
`01-startable-<voice>.m4a` through
`12-record-noun-question-<voice>.m4a`. Clip ranges come from the persisted
paragraph `alignment_anchor` rows, with small edge padding, so the synthetic
`Page N` narration is excluded.

## Narration QA and supporting ASR

Deterministic `echo-cli qa` completed all 12 chapters for each voice and retained
three open candidates per voice:

- `am_michael`: one pronunciation candidate on the synthetic `Page 2` heading,
  plus one insertion and one low-confidence candidate on the `filesystem`
  paragraph.
- `af_heart`: two low-confidence candidates (the synthetic `Page 12` heading and
  final question) plus one insertion candidate on the `filesystem` paragraph.

These are classifier candidates, not proof of an incorrect target
pronunciation. The sanitized reports remain at `qa-am_michael.json` and
`qa-af_heart.json` so the findings are not hidden.

As supporting evidence only, local whisper.cpp `tiny.en` transcribed the 24
heading-free clips. It produced 22/24 normalized exact matches. Both non-exact
results transcribed the compound `filesystem` as the semantically identical
two words `file system`; minimum string similarity was 0.98795. ASR normally
returns the same spelling for homographs and therefore does not prove the
`live`/`lives`/`record` vowel or stress choices.

## Human listening status

Pending. No claim in this report labels the target pronunciations as "heard
correct." The complete books and the 24 isolated case clips are available in the
external run directory for human review.
