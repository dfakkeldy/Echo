# Task 3 Report: Complete Currency Phrase Integration

## Status

Completed. Valid complete currency expressions are now collapsed before per-token phonemization into one semantic token with an exact source surface, exact spoken alias, source-span metadata, boundary range and whitespace, and rating `4`. Rejected candidates remain intact.

## Implementation

- Added optional `currencyExpressionSource` metadata to `Underscore`, including initializer, copy, and merged-token propagation.
- Reworked `EnglishG2P.retokenize(_:)` to flatten initial token splits once, scan left-to-right for the supported currency grammar, parse a complete candidate with `EnglishCurrencyExpression.parse(_:)`, and replace only accepted ranges.
- Each accepted range produces one alias-bearing `MToken`; its `text` and `currencyExpressionSource` are the exact consumed source, its `tokenRange` and whitespace come from the boundary tokens, and its spoken form is phonemized through the ordinary English G2P path.
- Removed the old one-token `var currency` and `canCarryPendingCurrency` state.
- Preserved rejected symbols, signs, numbers, magnitudes, and punctuation without partial semantic normalization.

## Changed files

- `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/EnglishG2P.swift`
- `ThirdParty/MisakiSwift/Sources/MisakiSwift/DataStructures/MToken.swift`
- `ThirdParty/MisakiSwift/Tests/MisakiSwiftTests/EnglishCurrencyExpressionTests.swift`
- `EchoTests/MisakiPronunciationMarkupTests.swift`
- `.superpowers/sdd/2026-08-03-pronunciation-reliability-program/task-3-report.md`

## RED

Command:

```text
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- swift test --package-path ThirdParty/MisakiSwift
```

Result: exit 1 during test compilation. Relevant output reported that `Underscore` had no member `currencyExpressionSource`. Expected reason: the end-to-end tests referenced the required semantic token metadata before production support existed.

Command:

```text
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Result: exit 2 / Xcode error 65 while compiling `EchoTests/MisakiPronunciationMarkupTests.swift` for the same absent metadata. Build-slot/resource deferrals were not counted as RED evidence.

The first production package run then exposed a second behavioral defect: complete phrases had rating `1` and lost spoken units because a multiword alias alone entered the fallback path. The semantic token was corrected to obtain phonemes for its spoken alias through ordinary G2P before the final GREEN runs.

## GREEN

Command:

```text
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- swift test --package-path ThirdParty/MisakiSwift
```

Result: exit 0. Relevant output:

```text
Test malformedSupportedSymbolCandidateRemainsIntact(source:) with 6 test cases passed
Test supportedExpressionBecomesOneSemanticToken(source:spoken:) with 20 test cases passed
Suite EnglishCurrencyExpressionTests passed
Test run with 34 tests in 3 suites passed after 14.392 seconds.
```

Command:

```text
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Result: exit 0 with `** TEST BUILD SUCCEEDED **`.

Command:

```text
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MisakiPronunciationMarkupTests
```

Result: exit 0 with `** TEST EXECUTE SUCCEEDED **`; 3 tests in 1 suite passed with 0 failures in 0.478 seconds.

## Self-review

- Compared all 20 required supported expressions against the reconstructed spoken/token surface, exact alias, exact source metadata, single-token span, and rating.
- Confirmed sentence punctuation remains outside the semantic span and trailing whitespace remains attached to the consumed boundary token.
- Confirmed malformed candidates reconstruct both the original source surface and alias-based spoken surface exactly, emit no empty token, emit no empty phonemes for a letter-bearing token, and receive no semantic currency metadata.
- Confirmed non-currency magnitude prose receives no currency metadata.
- Confirmed parser misses advance one original token at a time, so they cannot discard partially scanned candidates.
- Confirmed the legacy pending-currency variables are gone and `mergeTokens(_:)` carries the new metadata only when the merged input has one unique semantic source.
- Confirmed `git diff --check` passes.

## Commit

This report is included in the local commit with subject `feat(narration): normalize complete currency phrases`. The final SHA is reported in the task handoff.

## Concerns and proof limits

- No concern remains within Task 3's requested scope.
- Verification covers the complete MisakiSwift package suite, an Echo test build, and the focused 3-test Echo markup suite. It does not claim the full Echo unit suite, hosted CI, device, renderer/audio, listening, or human acceptance.
- Task 4 diagnostics, cache-version changes, and runtime failure reporting were intentionally not implemented.
