# Echo Pronunciation Reliability Program Design

Date: 2026-08-03

Status: Approved conversational design; written specification awaiting user review

## 1. Goal

Improve Echo's English narration across four distinct failure classes without
allowing uncertain automation to override trusted human or deterministic
evidence:

1. incorrect spoken-number and currency normalization;
2. incorrect pronunciations for unknown or disputed words;
3. incorrect contextual selection for homographs;
4. acoustically incorrect Kokoro output despite reasonable input phonemes.

The program must continue narration when it finds uncertainty and present a
local advisory review rather than blocking a long render.

## 2. Product outcome

After the program:

- supported currency expressions are spoken in natural English, including
  `$100 billion` as "one hundred billion dollars";
- unknown or disputed pronunciations carry auditable candidate evidence;
- a qualified CPU ONNX G2P fallback may replace the current deterministic
  fallback for eligible out-of-vocabulary words;
- contextual homograph families may graduate independently from shadow mode;
- acoustic defects are distinguished from text-normalization and G2P defects;
- iOS, macOS, and headless narration expose the same non-blocking pronunciation
  review evidence;
- explicit occurrence, per-book, and global corrections remain authoritative;
- all private book text, review evidence, and audio remain local by default.

Completing the program does not require forcing an experimental model into
production. A component that fails its qualification gate remains shadow-only
while independently proven improvements ship.

## 3. Non-goals

This program does not:

- replace the Kokoro acoustic model;
- add another narration engine or silently fall back to a system voice;
- embed or ship eSpeak;
- silently change the reader's selected Kokoro voice;
- send private book text, narration audio, or pronunciation evidence to a
  remote service;
- allow one dictionary or model disagreement to overwrite an existing trusted
  lexicon entry automatically;
- add non-English G2P;
- lower the existing contextual-family qualification thresholds;
- treat ASR or a machine audio judge as human listening evidence.

## 4. Project constraints

- Preserve the deployment floors: iOS 18, macOS 15, and watchOS 11.
- Preserve Swift 6 concurrency and the existing observation architecture.
- Keep model loading, G2P inference, corpus evaluation, audio inspection, and
  report generation off the UI actor.
- Reuse Echo's existing ONNX Runtime dependency. Adding a different third-party
  runtime requires separate user authorization.
- Narration must remain usable while the app is backgrounded or the iPhone is
  locked.
- No model download may occur while a chapter is being narrated. Production
  model resources must be pinned, integrity-checked, and available before use.
- User and occurrence overrides remain the highest pronunciation authority.
- Every production-byte change must participate in narration cache identity.
- App, CLI, CI, physical-device, rendered-audio, and human-listening evidence
  remain separate proof states.

## 5. Current failure boundaries

### 5.1 Number conversion

The vendored `EnglishNum2Word` tens table omits `20`. Values from 21 through 29
therefore cannot resolve their tens component correctly.

### 5.2 Currency magnitude ordering

Misaki's retokenizer currently attaches the pending currency to the immediately
following numeric token. A later magnitude token is handled separately, so
`$100 billion` becomes the semantic sequence "one hundred dollars billion."

### 5.3 Unlimited low-confidence fallback

The current deterministic OOV fallback guarantees a vocab-safe, plausible
pronunciation for open-ended spellings. It does not guarantee linguistic
correctness. Because the OOV vocabulary is unbounded, this creates an unbounded
source of plausible but incorrect narration.

### 5.4 Missing disagreement evidence

The supplemental CMUdict pack intentionally excludes spellings already present
in Misaki's gold or silver lexicons. This is safe for automatic production
selection, but it also discards useful audit evidence when two sources disagree.
The current simple preflight finds fallback hits, acronyms, likely proper nouns,
and empty output; it does not flag known-word source disagreements.

### 5.5 Context and acoustics

Echo has deterministic contextual rules and a shadow contextual-analysis
system, but only independently qualified families may gain production
authority. Separately, Kokoro may render reasonable IPA incorrectly for a
particular voice or context. Those acoustic failures must not be repaired by
globally corrupting correct lexical data.

## 6. Ordered narration architecture

Every narration path uses this authority order:

1. deterministic spoken-text normalization;
2. occurrence-specific human overrides;
3. per-book and global human overrides;
4. qualified deterministic contextual rules;
5. trusted bundled lexicon selection;
6. qualified neural fallback for genuine OOV words;
7. existing deterministic OOV fallback as the final voiced safety net;
8. non-blocking audit materialization;
9. Kokoro synthesis and bounded same-voice acoustic handling.

Candidate comparison may observe every stage, but lower-authority evidence may
not replace a higher-authority decision merely because it reports a larger
numeric confidence value.

## 7. Deterministic number and currency normalization

### 7.1 Boundary

Cardinal number correctness remains in the vendored MisakiSwift
`EnglishNum2Word` implementation. Currency phrase assembly remains beside
`EnglishG2P.retokenize`, where the currency symbol, signed amount, optional
magnitude, and following punctuation can be interpreted before phonemes are
assigned to individual tokens.

This keeps general English G2P behavior correct for every Echo caller instead
of patching one narration entry point.

### 7.2 Supported grammar

The complete supported class is:

```text
[sign] currency-symbol amount [magnitude]
currency-symbol [sign] amount [magnitude]
```

Where:

- `sign` is an optional minus sign;
- `currency-symbol` is `$`, `£`, or `€`;
- `amount` accepts digits, one decimal separator, and correctly placed comma
  grouping;
- `magnitude` is `thousand`, `million`, `billion`, or `trillion`, matched
  case-insensitively as a whole token.

Magnitude abbreviations such as `M`, `MM`, `B`, and `bn`, ISO currency codes,
locale-specific decimal commas, and unsupported currency symbols are outside
this program. They remain unchanged and may be proposed later from confirmed
failures.

### 7.3 Currency vocabulary

Currency metadata carries explicit singular and plural forms for both major and
minor units:

| Symbol | Major singular | Major plural | Minor singular | Minor plural |
| --- | --- | --- | --- | --- |
| `$` | dollar | dollars | cent | cents |
| `£` | pound | pounds | penny | pence |
| `€` | euro | euros | cent | cents |

Singular is selected only when the semantic unit count is exactly one.
Magnitude expressions such as `$1 million` therefore end in "dollars," while
`$1` ends in "dollar."

### 7.4 Spoken-form requirements

Required examples include:

| Input | Spoken form |
| --- | --- |
| `21` | twenty-one |
| `$1` | one dollar |
| `$2` | two dollars |
| `$1.01` | one dollar and one cent |
| `$0.50` | fifty cents |
| `£0.01` | one penny |
| `£0.02` | two pence |
| `€1.01` | one euro and one cent |
| `$5.5 million` | five point five million dollars |
| `$100 billion` | one hundred billion dollars |
| `£1.5 million` | one point five million pounds |
| `€2 trillion` | two trillion euros |
| `-$2 billion` | minus two billion dollars |
| `$-2 billion` | minus two billion dollars |
| `$1,234.56` | one thousand, two hundred and thirty-four dollars and fifty-six cents |

Trailing fractional zeros in a scaled amount do not create unnatural speech:
`$1.0 million` is "one million dollars" and `$5.50 million` is "five point
five million dollars." A leading fractional form such as `$.5 million` is
"zero point five million dollars."

An unscaled decimal uses major/minor currency units when it has at most two
fractional digits. A scaled decimal speaks the decimal value followed by the
magnitude and plural major unit; it does not reinterpret the fraction as cents.

### 7.5 Fail-closed behavior

Malformed grouping, multiple decimal points, an unsupported magnitude, or a
symbol not followed by a numeric amount does not enter the currency grammar.
The original token sequence proceeds through existing behavior and produces an
advisory diagnostic when it contains a supported currency symbol. Normal prose
such as "100 billion people" receives no currency unit.

## 8. Pronunciation authority and candidate selection

### 8.1 Authority levels

Candidate evidence uses categorical authority rather than an uncalibrated
cross-provider score:

- `trusted`: explicit human override, qualified deterministic rule, or
  unambiguous bundled lexicon decision;
- `qualified`: a versioned neural or contextual selection policy that passed
  every applicable production gate;
- `uncertain`: a fallback, ungraduated model result, unresolved multi-source
  disagreement, or invalid candidate.

### 8.2 Automatic selection policy

- Explicit overrides always win and suppress automated replacement.
- A qualified deterministic contextual rule may select its reviewed output.
- An unambiguous trusted lexicon entry remains authoritative.
- The neural fallback may select automatically only for a genuine OOV spelling
  and only when the exact model, conversion, validation, and selection policy
  version is qualified.
- A known-word disagreement remains advisory unless a separately reviewed rule
  or contextual family is graduated.
- Invalid, empty, duplicate, or Kokoro-incompatible candidates are never
  eligible for selection.
- If no qualified candidate is eligible, the deterministic fallback voices the
  word and the audit records uncertainty.

### 8.3 Comparison scope

Candidate comparison is limited to words with a reason to inspect:

- current fallback/OOV use;
- multiple trusted pronunciations;
- disagreement between bundled sources;
- membership in a contextual homograph family;
- a likely acronym or proper noun;
- empty or unsupported phoneme output;
- an existing review/watch-word request.

Ordinary unanimous lexicon words do not invoke neural inference.

## 9. Existing audit spine

The implementation extends these existing types instead of adding a parallel
pronunciation-report subsystem:

- `PronunciationAuditDecision`;
- `PronunciationAuditDiagnostic`;
- `PronunciationAuditManifest`;
- `PronunciationDecisionSeed`;
- `NarrationPronunciationPreflight`;
- `PronunciationListeningReel`;
- the existing headless narration audit output.

Each disputed or automatically selected occurrence records:

- normalized and display spelling;
- local sentence context sufficient for review;
- selected IPA and source;
- alternative IPA candidates and sources;
- candidate and policy version identities;
- categorical authority;
- selection or abstention reason;
- validation state;
- whether an explicit override suppressed automation;
- chapter/block/occurrence identity;
- rendered audio range when available;
- whether the issue is lexical, contextual, or acoustic.

The local manifest may contain source context because it never leaves the
device by default. Durable public receipts contain only content-free counts,
hashes, version identities, and proof states.

### 9.1 Advisory behavior

- Preflight may run before or alongside chapter rendering.
- Rendering never waits for pronunciation review.
- iOS and macOS show a non-blocking "Pronunciation review available" state.
- Repeated occurrences are grouped by spelling and selected pronunciation.
- Contextual words preserve separate occurrence rows when their sentence
  evidence or selected sense differs.
- Accepting a correction uses the existing occurrence, per-book, or global
  override paths.
- Headless narration emits the same decisions and diagnostics in its manifest
  and listening reel.

Shadow-only candidate evidence is excluded from synthesis/cache identity.
Production-authoritative selection and policy versions are included.

## 10. Neural ONNX fallback

### 10.1 Qualification-first integration

The first implementation is an offline evaluator using Echo's existing ONNX
Runtime. The initial candidate is the permissively licensed Mini-BART English
G2P ONNX model identified during research, but the program qualifies the
behavioral contract rather than pre-authorizing that particular artifact.

Before any production use, the selected artifact must have:

- verified source and data-license compatibility;
- an immutable upstream revision;
- exact file hashes and sizes;
- bundled attribution and license notices;
- reproducible ARPAbet-to-Kokoro-IPA conversion;
- a versioned selection and phoneme-validation policy.

If the candidate cannot satisfy those requirements, it remains a development
comparison and no model resource is shipped.

### 10.2 Runtime behavior

- Use one cached CPU ONNX session, never one session per word.
- Keep session creation and inference off the UI actor.
- Propagate cancellation between words and chapters.
- Perform no model download during narration.
- Validate every emitted phoneme against Kokoro's production vocabulary.
- Treat load, integrity, inference, decoding, cancellation, and validation
  failures as categorized advisory evidence.
- Fall back to the deterministic OOV path without blocking narration.

Production activation is limited to OOV selection. Known-word and contextual
disagreements remain advisory unless they independently graduate.

## 11. Contextual homograph graduation

The existing `HomographPronunciationResolver`, contextual discovery, runtime
family identity, and qualification corpus remain the authority boundary.

The initial families are:

- `content`;
- `read`;
- `live` / `lives`;
- `record`.

Each family graduates independently. A failing family remains shadow-only and
does not disable a proven family. An unknown OS/model runtime family returns to
shadow behavior. A low-confidence, malformed, unsupported, unavailable, or
unfamiliar context abstains and becomes advisory.

The program does not reinterpret provisional, agent-generated, model-generated,
or machine-judge labels as human evidence.

## 12. Acoustic defect handling

Correct IPA does not prove correct audio. Echo therefore preserves two
separate diagnoses:

- lexical/contextual defect: the selected semantic pronunciation was wrong;
- acoustic/voice defect: the selected IPA was reasonable but Kokoro rendered it
  incorrectly.

For an acoustic defect, Echo may perform one bounded retry using the same
selected voice with adjusted context or smaller chunking. It must preserve the
same intended pronunciation and may not silently switch voices. If the retry
does not pass the mechanical quality gate, Echo keeps the rendered result under
existing failure policy and adds an acoustic advisory entry.

ASR and the development audio judge may prioritize likely failures. They may
not rewrite IPA automatically, graduate a family, or count as human listening.

## 13. Error handling

| Failure | Production behavior | Evidence |
| --- | --- | --- |
| Malformed currency phrase | Preserve existing token flow | Currency-normalization diagnostic |
| Missing/corrupt neural model | Use deterministic fallback | Model-unavailable or integrity diagnostic |
| Neural inference cancelled | Propagate chapter cancellation | Cancellation category; no partial authority |
| Empty/unsupported neural output | Reject candidate; use deterministic fallback | Candidate-validation diagnostic |
| Candidate sources disagree | Keep higher authority or fallback | Advisory alternatives and reason |
| Context model unavailable/unknown runtime | Keep deterministic authority | Shadow/unavailable diagnostic |
| Context model abstains | Keep deterministic authority | Review advisory |
| Correct IPA but poor audio | One same-voice retry | Acoustic diagnostic and both render identities |
| Audit/report write fails | Preserve narration result; surface report failure | Local operational error |

No diagnostic failure may make a letter-bearing word silent or terminate an
otherwise viable book render.

## 14. Privacy and provenance

- Candidate comparison and neural inference run locally.
- Private book text, titles, authors, paths, user identifiers, and audio do not
  enter public fixtures, logs, or committed reports.
- Qualification corpora use public-domain, permissively licensed, or synthetic
  examples plus separately supplied trusted human receipts.
- Model and pack artifacts carry immutable provenance, semantic versions,
  hashes, and required notices.
- Machine-generated evaluation remains explicitly provisional.
- Public qualification receipts distinguish unit tests, corpus qualification,
  hosted CI, rendered audio, eligible-device execution, and human listening.

## 15. Qualification gates

### 15.1 Deterministic number and currency gate

The test matrix covers all supported currencies and magnitudes across:

- singular and plural major units;
- singular and plural minor units;
- zero, one, tens, hundreds, and 20–29;
- integers and decimals;
- leading and trailing fractional zeros;
- both supported minus-sign positions;
- valid comma grouping;
- punctuation and sentence boundaries;
- magnitude/no-magnitude pairs;
- malformed and unsupported negative controls;
- non-currency number prose.

Every named expected spoken form and negative control must pass. Invalid or
empty phoneme output must remain zero.

### 15.2 Neural fallback gate

Qualification evaluates the complete selection policy on at least 500
independently reviewed public or synthetic OOV cases, with at least 75 cases in
each of these categories:

- proper nouns;
- technical terms;
- productive and irregular morphology;
- loanwords used in English prose;
- adversarial English spellings.

The remaining cases may increase any category. Automatic activation requires:

- at least 99 percent precision among automatically selected pronunciations;
- a 95 percent Wilson lower confidence bound of at least 98 percent;
- zero empty, unsupported, duplicate, or unmappable outputs;
- no systematic category, capitalization, punctuation, or sentence-position
  failure;
- stable repeated output for the same model and policy identities;
- human-listened rendered probes on the primary and at least one control voice;
- added peak resident memory no greater than 64 MB;
- cold preflight no greater than two seconds per book on the oldest supported
  physical test iPhone;
- sustained preflight no greater than five percent of the measured Kokoro
  narration render time for the same source;
- successful cancellation, relaunch, and lock-screen/background rendering on a
  physical iPhone.

Failure leaves the model shadow-only. It does not block deterministic fixes,
auditing, contextual qualification, or acoustic improvements.

### 15.3 Contextual family gate

Preserve the existing family gate without weakening it:

- at least 200 qualifying human-labelled cases per family;
- at least 50 cases per sense;
- named regressions and negative guards 100 percent correct;
- held-out automatic precision at least 99 percent;
- 95 percent Wilson lower confidence bound at least 98 percent;
- automatic coverage at least 95 percent overall;
- automatic coverage at least 90 percent for every sense;
- zero invalid, missing, duplicate, or unsupported output;
- no systematic context, genre, capitalization, or position failure;
- stable repeated runs on the qualified runtime;
- valid production Kokoro IPA only;
- human-listened primary and control voice probes.

### 15.4 Acoustic gate

Render every named regression, balanced held-out probes, and unambiguous
controls using the primary voice and at least one control voice. Mechanical
checks verify:

- non-empty audio;
- exact intended phoneme consumption;
- positive and bounded timing;
- no clipping;
- no silence/dropout failure;
- retry count never exceeds one;
- same-voice identity is preserved.

Human listeners judge semantic correctness and naturalness. Machine evidence
can prioritize samples but cannot pass the gate.

### 15.5 Book-level release gate

Before qualified automation becomes the default:

- mean unresolved review burden is no more than one item per narrated hour;
- P95 is no more than two unresolved items per hour;
- no tested book exceeds three unresolved items per hour;
- silently dropped phonemes remain zero;
- private production log leakage remains zero;
- deterministic fallback works on iOS 18 and macOS 15;
- latency and memory gates pass on the oldest physical test devices.

## 16. Verification layers

Verification proceeds from narrow to broad:

1. MisakiSwift unit tests for cardinal and currency tokenization;
2. pronunciation pack and corpus tooling tests;
3. focused Echo render-plan, G2P, preflight, audit, contextual, cache, and
   acoustic retry tests;
4. complete `make test` through the repository's Apple build-slot wrapper;
5. Release `echo-cli` build through the same wrapper;
6. direct G2P probes and deterministic audit manifests;
7. real production-path narration renders and sidecar verification;
8. bounded human listening reels;
9. hosted CI;
10. physical-iPhone foreground, lock-screen, cancellation, relaunch, and
    background acceptance.

A passing lower layer is not reported as proof of a higher layer.

## 17. Cache and identity rules

- Fixing number or currency normalization changes synthesis input and requires a
  narration render-version/cache-identity change.
- Shadow-only candidate evidence is excluded from production synthesis identity.
- Neural model, model bytes, ARPAbet conversion, validation policy, and selection
  policy identities participate in cache identity once they gain authority.
- Each graduated contextual family and runtime qualification participates in
  production plan identity.
- Acoustic retry-policy changes that can alter final bytes participate in cache
  identity.
- Occurrence, per-book, and global overrides continue to invalidate affected
  narration through the existing content-signature path.

## 18. Staged delivery

### Stage 1 — Deterministic correctness

- Fix 20–29.
- Implement the complete supported currency/magnitude grammar.
- Add the full deterministic test matrix.
- Bump production render/cache identity.
- Verify with real rendered examples.

### Stage 2 — Disagreement-aware advisory review

- Preserve CMUdict overlaps as audit-only alternatives.
- Extend audit decisions, diagnostics, manifests, and listening reels.
- Add iOS, macOS, and headless non-blocking review surfaces.
- Keep all new comparison evidence shadow-only.

### Stage 3 — Neural OOV shadow evaluation

- Integrate the candidate ONNX model into offline tooling.
- Pin provenance and conversion identity.
- Run corpus, performance, memory, cancellation, and background gates.
- Record a qualification receipt without production authority.

### Stage 4 — Qualified neural OOV activation

- Activate only if every Stage 3 gate passes.
- Limit authority to eligible OOV decisions.
- Include production policy identity in cache signatures.
- Preserve deterministic fallback for every failure and abstention.

### Stage 5 — Contextual family graduation

- Obtain independently trusted labels.
- Qualify and graduate `content`, `read`, `live/lives`, and `record`
  independently.
- Leave every failing or unknown runtime family shadow-only.

### Stage 6 — Acoustic diagnosis and retry

- Separate lexical and acoustic issue categories.
- Add one bounded same-voice retry strategy.
- Run mechanical and human-listening gates.
- Keep persistent failures advisory.

### Stage 7 — Complete release proof

- Run the full local gates, hosted CI, production render probes, listening reel,
  and physical-device/background acceptance.
- Publish exact proof states without treating pending qualification as passing.

Each stage should be a coherent review boundary and may ship independently when
its own behavior is useful and proven. Later-stage failure does not roll back an
earlier deterministic improvement.

## 19. Acceptance criteria

The program is complete when:

- every deterministic currency and number example is correct;
- malformed inputs preserve speech and produce controlled diagnostics;
- advisory review is non-blocking and consistent across app and headless paths;
- candidate evidence is deterministic, versioned, local, and auditable;
- neural OOV selection is either qualified and narrowly activated or truthfully
  retained in shadow mode with a completed qualification receipt;
- contextual families are individually graduated or truthfully retained in
  shadow mode based on the existing gates;
- lexical and acoustic failures are represented separately;
- no path silently switches voice, drops a letter-bearing word, leaks private
  content, or gives a machine verdict human authority;
- production-affecting changes invalidate stale narration correctly;
- local tests, hosted CI, rendered audio, device execution, and human listening
  are reported as separate states.

## 20. Approved decisions

- Scope: the full staged program.
- Currency scope: `$`, `£`, and `€`; `thousand`, `million`, `billion`, and
  `trillion`; integers, decimals, signs, grouping, and correct inflection.
- Review behavior: continue rendering and show a non-blocking advisory.
- Architecture: guarded staged activation.
- Neural authority: OOV-only after qualification; known-word disagreements stay
  advisory.
- Context authority: family-by-family graduation using existing strict gates.
- Acoustic retry: at most one retry, same selected voice.
- Privacy: local-only by default.

No unresolved product or architecture decision remains in this specification.
Qualification results determine activation state but do not alter the approved
design.
