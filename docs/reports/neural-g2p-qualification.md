# Neural G2P Qualification

Qualification status: `WAITING_FOR_HUMAN_LABELS`

This report is generated from a content-free qualification receipt. Candidate
words, contexts, human labels, and model output strings are intentionally absent.

## Qualification evidence

- Corpus SHA-256: `6085b9bf06234dc263004348a2b2dc619055ee0617f6e7654ad3b7448cdfedb8`
- Reviewed cases: 0
- Automatic selections: 0
- Correct automatic selections: 0
- Exact automatic precision: unavailable
- 95% Wilson lower bound: unavailable
- Governed machine producer: `UNAVAILABLE_FAIL_CLOSED`
- Recomputed eligible observations (diagnostic only): 0

- `proper-noun`: 0 qualifying cases
- `technical`: 0 qualifying cases
- `morphology`: 0 qualifying cases
- `loanword`: 0 qualifying cases
- `adversarial`: 0 qualifying cases

## Invalid outputs

```json
{"emptyOrUnmappable":0,"missingMachineEvidence":0,"notDeterministicOOV":0,"unstable":0}
```

## Frozen identities

- Model: `jonschneider/mini-bart-g2p`
- Revision: `f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06`
- Lock SHA-256: `3c4a6f8f61d3d0b2070add2337f9aed23f5174327a3dfb0c9c62920ee6ca84e8`
- Kokoro vocabulary SHA-256: `ba536e2187cf4a12827b4e6138f29c17b795fcc3f8155386408d8d4edc229a41`
- Conversion version: `mini-bart-arpabet-to-kokoro-v1`
- Validation version: `kokoro-vocab-validation-v1`
- Selection version: `neural-oov-complete-selection-v1`

## Separate proof states

- Corpus proof: `CONTRACT_VALID`
- Human proof: `WAITING_FOR_HUMAN_LABELS`
- Performance proof: `NOT_PROVIDED`
- Device proof: `NOT_PROVIDED`
- Render proof: `NOT_PROVIDED`
- Listening proof: `NOT_PROVIDED`

These states are not inferred from corpus validation or human-label qualification.
Runtime and listening states are derived only from a bound external runtime
receipt and a distinct user-controlled listening authority receipt.

## Task 14 shadow-integration evidence

- Integration mode: `SHADOW_ONLY`
- Runtime model revision: `f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06`
- Runtime conversion policy: `mini-bart-arpabet-to-kokoro-v1`
- Runtime validation policy: `kokoro-vocab-validation-v1`
- Runtime shadow-selection policy: `mini-bart-g2p-beam5-max20-v1`
- Qualification selection policy: `neural-oov-complete-selection-v1`
- Full committed public/synthetic corpus checked: 540 provisional cases
- Repetitions per case: 2
- Stable repeated runtime results: 540 of 540
- Candidate-producing runtime results: 540 of 540
- Category coverage: 108 cases in each of the 5 governed categories
- Capitalization coverage: 180 lowercase, 180 titlecase, 180 uppercase
- Punctuation coverage: 135 none, 135 leading, 135 trailing, 135 paired
- Sentence-position coverage: 180 initial, 180 medial, 180 final
- Integration tests: `VERIFIED_BY_AUTOMATED_TESTS`
- Deterministic pronunciation selection unchanged: `VERIFIED_BY_AUTOMATED_TESTS`
- Shadow evidence excluded from cache/resume identity: `VERIFIED_BY_AUTOMATED_TESTS`
- Chapter cancellation propagation: `VERIFIED_BY_AUTOMATED_TESTS`

The runtime evidence above was collected with the bundled model in an iPhone
simulator test process. It is not physical-device, performance, audiobook
render, or human-listening evidence and does not change any separate proof state
or the overall `WAITING_FOR_HUMAN_LABELS` qualification status. The committed
corpus now contains more than 500 candidate cases, but all 540 remain provisional:
zero independently human-reviewed cases count toward the 500 reviewed-case
qualification floor.
