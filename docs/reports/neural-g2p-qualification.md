# Neural G2P Qualification

Qualification status: `WAITING_FOR_HUMAN_LABELS`

This report is generated from a content-free qualification receipt. Candidate
words, contexts, human labels, and model output strings are intentionally absent.

## Qualification evidence

- Corpus SHA-256: `7da7b877d00a064f4b18657e20b14df4527d20e9d3a4b2a16411ce04068af152`
- Reviewed cases: 0
- Automatic selections: 0
- Correct automatic selections: 0
- Exact automatic precision: unavailable
- 95% Wilson lower bound: unavailable

- `proper-noun`: 0 qualifying cases
- `technical`: 0 qualifying cases
- `morphology`: 0 qualifying cases
- `loanword`: 0 qualifying cases
- `adversarial`: 0 qualifying cases

## Invalid outputs

```json
{"duplicate":0,"empty":0,"kokoroIncompatible":0,"unmappable":0,"unstable":0}
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
- Performance proof: `NOT_RUN_NO_RUNTIME`
- Device proof: `NOT_RUN_NO_RUNTIME`
- Render proof: `NOT_RUN_NO_RUNTIME`

These states are not inferred from corpus validation or human-label qualification.

## Task 14 shadow-integration evidence

- Integration mode: `SHADOW_ONLY`
- Runtime model revision: `f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06`
- Runtime conversion policy: `mini-bart-arpabet-to-kokoro-v1`
- Runtime validation policy: `kokoro-vocab-validation-v1`
- Runtime shadow-selection policy: `mini-bart-g2p-beam5-max20-v1`
- Qualification selection policy: `neural-oov-complete-selection-v1`
- Full committed public/synthetic corpus checked: 10 provisional cases
- Repetitions per case: 2
- Stable repeated runtime results: 10 of 10
- Candidate-producing runtime results: 10 of 10
- Integration tests: `VERIFIED_BY_AUTOMATED_TESTS`
- Deterministic pronunciation selection unchanged: `VERIFIED_BY_AUTOMATED_TESTS`
- Shadow evidence excluded from cache/resume identity: `VERIFIED_BY_AUTOMATED_TESTS`
- Chapter cancellation propagation: `VERIFIED_BY_AUTOMATED_TESTS`

The runtime evidence above was collected with the bundled model in an iPhone
simulator test process. It is not physical-device, performance, audiobook
render, or human-listening evidence and does not change any separate proof state
or the overall `WAITING_FOR_HUMAN_LABELS` qualification status. The committed
corpus remains provisional and below the 500 reviewed-case qualification floor.
