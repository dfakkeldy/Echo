# Narration — OOV Word Fallback (no more silent "Jacqui") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

> **Status:** PLAN ONLY — no code changed in the introducing PR.

**Goal:** When an out-of-vocabulary word (e.g. the name "Jacqui") is narrated, the engine must **attempt a pronunciation** instead of emitting silence — and surface OOV words so the user can add a precise pronunciation override.

**Architecture:** The OOV path already has a seam (`EnglishFallbackNetwork`) that was deliberately stubbed to a no-op when the MLX/BART G2P was dropped. The fix replaces the stub's output so it never returns a glyph the phoneme vocab drops. A second, additive piece reports OOV surface words up through `NarrationService` to drive a "add a pronunciation?" prompt wired into the existing `PronunciationOverrideStore`.

**Tech Stack:** Swift, MisakiSwift (vendored G2P), Kokoro phoneme vocab, Swift Testing.

## Why "Jacqui" is silent (root cause, verified)

The word is not in the lexicon, so MisakiSwift falls back to `EnglishFallbackNetwork.callAsFunction`, which is a **stub returning `("❓", 1)`** ([EnglishFallbackNetwork.swift:23-25](ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift)). `❓` (U+2753) is **not** in Kokoro's vocab, so `KokoroPhonemeVocab.ids(forPhonemes:)` silently drops it (it only appends `if let id = charToId[char]`, [KokoroPhonemeVocab.swift:56-60](EchoCore/Services/Narration/KokoroPhonemeVocab.swift)). The word collapses to the surrounding space tokens → the model renders a brief silent gap. The file's own header even documents this: *"An OOV word returns the `unk` glyph ('❓'), which `KokoroPhonemeVocab` drops → the word is silent."*

- There is **no** rule-based letter-to-sound fallback today (the BART net was removed with MLX). The spell-out path `getNNP` exists in the lexicon but is unreachable for plain OOV words (only called for *known*/acronym/dotted inputs) ([Lexicon.swift:295-313](ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/Lexicon.swift)).
- The existing test **enshrines the bug**: `LexiconOnlyG2PTests.oovWordDegradesGracefullyDoesNotCrash` asserts `p.contains("❓")` ([LexiconOnlyG2PTests.swift:14-20](EchoTests/LexiconOnlyG2PTests.swift)). It must be inverted.
- There is **zero OOV logging/diagnostics** today — the drop is silent.

## Decisions made while you slept (override freely)

- **Make the fallback non-silent — never emit `❓`.** This is the one change that fixes the reported bug: change `EnglishFallbackNetwork.callAsFunction` so an OOV word always yields *some* vocab-mappable phonemes. This directly honors your "should be at least tried."
- **Use a small digraph/letter heuristic, not bare spell-out, as the default quality floor.** Spell-out ("J-A-C-Q-U-I", via the lexicon's `getNNP`-style letter IPA) is trivially correct but grating across a whole book. A tiny English grapheme→approx-IPA map (e.g. `qu→kw`, common digraphs, vowels) produces something like `ʤˈæki` — far more listenable, still cheap, and confined to the one stub file. Keep `❓` only as a true last resort for input with *no* mappable letters (pure symbols/emoji).
- **Add OOV surfacing (additive).** The fallback already has the `MToken`, so `word.text` is available; report the set of OOV surface words up through `NarrationService` so the UI can prompt: *"These names weren't recognized — tap to add a pronunciation,"* wiring into the existing `PronunciationOverrideStore.set(word:ipa:)` / `PronunciationDictionaryView`. The override feature stays the high-quality escape hatch.
- **Do not rebuild the neural BART G2P.** Out of scope; the heuristic + overrides cover the nonfiction workload.

## Open questions for Dan
1. Default flavor: digraph heuristic (recommended) vs plain spell-out for the immediate floor?
2. Keep `❓` as a last-resort for unmappable input, or drop it entirely?
3. OOV surfacing: wire the proactive "add a pronunciation?" prompt now, or logging-only first?
4. Confirm inverting `LexiconOnlyG2PTests.oovWordDegradesGracefullyDoesNotCrash` (it currently asserts the buggy `❓`).

## Global Constraints
- Branch target **`nightly`**. G2P is shared code → the fix lands once for iOS + macOS (narration surfaces). Run the `cross-platform-parity-reviewer` since both iOS `PlayerModel` and macOS batch call `NarrationService`.
- Behavior change to shared narration logic + the documented "OOV → ❓" contract → **doc-sync** CODE_AUDIT_NARRATION.md / narration-feature notes + update the `EnglishFallbackNetwork` header comment.
- Tests via `make build-tests` + `make test-only FILTER=…`.
- **Invariant (verbatim):** a real word must never produce only boundary/space tokens — it must contribute ≥1 non-`0`, non-`16` (space) token id.

## File Structure
- `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift` — **modify**: replace the no-op with a heuristic that never returns `❓` for letter-bearing words; update the header.
- `EchoTests/LexiconOnlyG2PTests.swift` — **modify**: invert the OOV test; add a non-silent-tokens assertion.
- `EchoTests/KokoroPhonemeVocabTests.swift` — **modify**: add the end-to-end "OOV produces real tokens" guard.
- (Phase 2, additive) `EchoCore/Services/Narration/NarrationService.swift` + the OOV reporting plumbing + a small UI hook into `PronunciationDictionaryView`.

---

## Phase 1 — Non-silent OOV fallback (fixes the reported bug)

### Task 1: Replace the silent stub with a best-effort phonemizer

**Files:**
- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift:23-25`
- Test: `EchoTests/LexiconOnlyG2PTests.swift`, `EchoTests/KokoroPhonemeVocabTests.swift`

**Interfaces:**
- Consumes: `MToken` (has `.text`); the existing Kokoro phoneme alphabet (the chars `KokoroPhonemeVocab` accepts).
- Produces: `(phoneme: String, rating: Int)` whose phoneme string is non-empty and entirely vocab-mappable for any letter-bearing word; `❓` only for input with no mappable letters.

- [ ] **Step 1: Invert the failing test** — assert an OOV word produces non-empty, `❓`-free phonemes.

```swift
// EchoTests/LexiconOnlyG2PTests.swift  (replace oovWordDegradesGracefullyDoesNotCrash)
@Test func oovWordIsPronouncedNotSilent() {
    let p = KokoroG2P().phonemes(for: "Jacqui")
    #expect(!p.isEmpty)
    #expect(!p.contains("❓"))
}
```

- [ ] **Step 2: Add the end-to-end silence guard** in `KokoroPhonemeVocabTests` — encode an OOV-only string and assert at least one real (non-boundary, non-space) token id.

```swift
@Test func oovProducesRealTokensNotSilence() throws {
    let ids = try KokoroPhonemeVocab().ids(forPhonemes: KokoroG2P().phonemes(for: "Jacqui"))
    #expect(ids.contains { $0 != 0 && $0 != 16 })  // not just BOS/EOS + spaces
}
```

- [ ] **Step 3: Run both → fail** (`make test-only FILTER=EchoTests/LexiconOnlyG2PTests` and `…/KokoroPhonemeVocabTests`). Current behavior returns `❓` / silence.

- [ ] **Step 4: Implement the heuristic** in `callAsFunction`. Map the word's letters to approximate Kokoro IPA via a small ordered rule table (multi-char digraphs first, then single letters), lowercasing first; only emit `unk` if the result is empty. Illustrative:

```swift
func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int) {
    let ipa = Self.approximateIPA(for: word.text)   // ordered digraph→letter rules, vocab-safe
    return ipa.isEmpty ? (unk, 1) : (ipa, 1)        // rating 1 = low-confidence fallback
}
```

Keep every emitted symbol inside the Kokoro vocab alphabet (verify against `_kokoro_vocab.json` keys) so nothing gets silently dropped downstream.

- [ ] **Step 5: Run → pass.** Then run `make test` to confirm no regression in `KokoroG2PTests` / `KokoroFrontEndTests` (known words must be unchanged — the fallback only fires on lexicon misses).

- [ ] **Step 6: On-device check (Dan)** — narrate a passage containing "Jacqui": it now speaks an approximation instead of a gap.

- [ ] **Step 7: Update the header comment** in `EnglishFallbackNetwork.swift` to describe the heuristic (not "→ silent"), and **commit**:

```bash
git add ThirdParty/MisakiSwift/.../EnglishFallbackNetwork.swift EchoTests/LexiconOnlyG2PTests.swift EchoTests/KokoroPhonemeVocabTests.swift
git commit -m "fix(narration): OOV words get a best-effort pronunciation, never silence"
```

---

## Phase 2 — Surface OOV words for overrides (additive, optional)

### Task 2: Report OOV surface words from a render

**Files:** Modify `EchoCore/Services/Narration/NarrationService.swift` + the G2P→service plumbing.

**Interfaces:**
- Consumes: the fallback firing with `word.text`.
- Produces: a per-render `Set<String>` of OOV surface words exposed on `NarrationService` (and/or `NarrationState`).

- [ ] **Step 1: Failing test** — render text containing a known OOV name with a `MockTTSEngine` path that records OOV words; assert the OOV set contains "Jacqui" and excludes all-known prose.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Thread an OOV collector from the fallback up to `NarrationService` (without coupling the engine to UI). Deduplicate; cap size.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5: Commit:** `git commit -m "feat(narration): collect OOV words during render for override prompts"`

### Task 3: "Add a pronunciation?" prompt (UI)

**Files:** Modify the narration status/picker surface + reuse `PronunciationDictionaryView` / `PronunciationOverrideStore.set(word:ipa:)`.

- [ ] **Step 1:** After a render, if OOV words exist, show a non-blocking nudge listing them; tapping one deep-links into the pronunciation editor pre-filled with that word.
- [ ] **Step 2:** Confirm adding an override re-renders that book correctly (override applies at the text layer in `NarrationService` after `TextNormalizer`, before chunking — already wired) and the cache invalidates (overrides change the text → different audio; confirm the cache key accounts for it or the user re-narrates).
- [ ] **Step 3:** Manual check (Dan): narrate → see "Jacqui not recognized" → add IPA → re-narrate → correct pronunciation.
- [ ] **Step 4: Commit:** `git commit -m "feat(narration): prompt to add pronunciations for unrecognized names"`

---

## Self-review notes
- **Spec coverage:** "at least tried" → Phase 1 (never silent). "should" implies discoverability → Phase 2 (surface + override). Both covered.
- **No placeholders:** failure path pinned to `EnglishFallbackNetwork.swift:24` + `KokoroPhonemeVocab.swift:57`; tests have concrete code.
- **Risk:** low — the change is confined to the OOV branch; known words are untouched (guarded by re-running `KokoroG2PTests`). The end-to-end token test prevents a future regression back to silence.
- **Cross-platform:** shared G2P → one fix covers iOS + macOS narration; no watch/widget impact.
