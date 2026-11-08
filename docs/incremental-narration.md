# Incremental narration re-render

A small edit to a narrated book should not re-synthesize the whole book.
`echo-cli narrate --synthesis-cache DIR` keeps every synthesized chunk in a
book-stable directory. A later render of the edited book replays all chunks
whose inputs did not change and synthesizes only the rest. The M4B, chapter
files and alignment sidecar are then rebuilt from that audio as usual.

## Workflow

1. Render once with a cache directory that belongs to the book, not to the
   run:

   ```sh
   echo-cli narrate --epub book.epub --out run-1/book.m4b \
     --sidecar run-1/book.alignment.json --work-dir run-1/work \
     --voice-plan voices.json --title "…" --author "…" \
     --synthesis-cache book-synthesis-cache
   ```

2. Edit the frozen EPUB (one sentence, one `ssml:ph`, one PLS entry).
3. See what the edit costs, without loading a model or writing anything:

   ```sh
   echo-cli narrate --epub book.epub --out run-2/book.m4b \
     --voice-plan voices.json --title "…" --author "…" \
     --synthesis-cache book-synthesis-cache --dry-run
   ```

   Each `RENDER` line names one block (`ch<N> s<i>-b<j>`, its voice, the
   number of chunks to synthesize, and the start of its text). The last line
   is the summary: `DRY_RUN 1 of 212 blocks to render (2 of 431 chunks);
   chapters with changes: 3`.
4. Render again with a new output and work directory and the same cache. The
   run prints `SYNTHESIS_CACHE <reused> reused, <synthesized> synthesized`.
5. Verify as usual: `echo-cli verify-sidecar --epub … --audio … --sidecar …`.

## What is reused

The reuse unit is one engine call: a `PlannedSynthesisChunk`, which is at most
one paragraph block (long blocks split under the model's ~510-phoneme window).
The cache key is a SHA-256 over everything the engine consumes:

| Input | Why it is in the key |
| --- | --- |
| Display text, G2P text, phonemes, phoneme IDs, word count, word groups | The exact model input and the word-timing map |
| Pronunciation fallback hits | Returned with the audio as review evidence |
| Voice and renderer family | Voice and model family |
| SHA-256 of the voice pack (`.f32`, `.rows`) and duration head | These load from disk (`ECHO_RESOURCE_DIR` or the bundle), not from the binary |
| `renderVersion` | Renderer behaviour pin |
| SHA-256 of the `echo-cli` executable | Any other renderer build reuses nothing |
| Word timings on or off | Changes the returned timings |

The key is computed from the frozen plan, after normalization, inline
`ssml:ph` and PLS markup, user and occurrence overrides, homographs and
contextual choices. So it covers the lexicon entries a block actually uses
without tracking them. If an edit to one block changes how a neighbour is
planned, the neighbour's phonemes change and it is synthesized again. If not,
it is reused.

Chunks are already separate engine calls that the renderer joins sample by
sample. A replayed chunk is the same Float32 PCM that a fresh call returned, so
reuse adds no new joins and no audible seams. Sentence-level splicing inside a
chunk was not chosen: it would cut the model's prosody mid-utterance and change
today's audio.

## What is rebuilt every time

- Planning (normalization, G2P and pronunciation choices) for the whole book.
- Silence between blocks and the chapter lead-out pad. They come from the plan,
  so reused and fresh audio get the same spacing.
- Chapter `.m4a` encoding, capture receipts, the M4B and the sidecar. Times in
  the sidecar are recomputed from the new chapter durations, so every block
  after an edit gets its shifted timestamp.
- The pronunciation audit and listening reel.

The tolerance is defined at the PCM level. Cached chunks replay byte-identical
Float32 samples, and an untouched chapter's `.m4a` decodes to sample-identical
audio; the test suite checks both. The encoded `.m4a` and M4B bytes are not
identical between runs, because AVFoundation's writer stamps container
metadata. The chapter that holds the edit is encoded again from start to end.

## Safety

- Capture receipts and resume validation are unchanged. A changed source still
  gets a new capture set, and `--resume` still fails closed on a mismatch.
- Every cache entry stores its key and the SHA-256 of its PCM. A corrupt,
  truncated or misfiled entry is a miss and is synthesized again.
- Audio that fails the quality check (empty, near-silent or implausibly short)
  is never stored. Echo's retry of that chunk reaches the engine, and a later
  run tries it fresh.
- The dry run takes no run lease and loads no voice model, so it is safe while
  another render owns the renderer. It predicts first attempts only: a chunk
  that fails the quality check is split and retried at render time.
- Delete the cache directory to force a full re-synthesis.
- If the duration head fails to load during a render, chunks are stored
  without word timings. Delete the cache if a later render should restore them.

## Size

Entries are raw Float32 PCM at 24 kHz: about 5.8 MB per minute of speech, or
about 0.5 GB for an 80-minute book. Each edit adds entries for the changed
chunks only, and every new renderer build starts a fresh set of keys.

Add `--prune-synthesis-cache` to a render that covers the whole book in one
process (no `--max-chapters` split). After the book completes, it deletes every
entry that render did not use, so the cache holds exactly the latest render.
It deletes only files named like cache entries, and only when the directory
belongs to this book: the first render records the title and author in
`book-identity.txt`, and a render of any other book never prunes it. Without
pruning, entries from older renderer builds stay on disk until you remove
them. Remove a book's cache when its final render is accepted.
