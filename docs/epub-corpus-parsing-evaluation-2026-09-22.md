# EPUB corpus parsing evaluation — 2026-09-22

## Corpus and method

The local book vault contained 1,685 EPUB files. A fixed, SHA-256-deduplicated
sample contains 360 distinct archives: 300 development books and 60 held-out
books. Selection covered publisher and generator metadata, EPUB package
versions, image density, and archive sizes. The sample spans 300 publisher
labels, 34 generator labels (307 files omit a useful generator), 29 nonempty
first-subject labels, 263 EPUB 2 packages, 96 EPUB 3 packages, and one package
marked 1.0. It includes 172 image-rich books. The 60 held-out books have publisher
and normalized generator groups absent from development where metadata permits.
The first provisional holdout was exposed by an early diagnostic sample; those
books became development data, and a fresh 60-book holdout was reserved before
any parser change. This is an evaluation split, not a random claim of
representativeness of all EPUB publishing.

The private manifest records archive paths, SHA-256 digests, and the split.
Neither it nor the exported text is committed. Original EPUBs were read only.
`echo-cli export-blocks` runs `SidecarSourceBlockLoader`, which imports through
Echo's EPUB scanner and shared `parseEPUBBlocks` path into an in-memory
`DatabaseService`. It does not open the normal library database. A source-only
scan of OPF, XHTML, NCX, and navigation markup supplied evidence for comparison;
it did not replace Echo's parser.

## Confirmed patterns and rules

| Development evidence | Shared-parser rule | Counterexample and expected effect |
| --- | --- | --- |
| Explicit lower-level XHTML headings, especially longer `<h3>`–`<h6>` text, were scored down to paragraphs. | `EPUBHeuristicEngine.score` keeps a nonempty explicit `<h1>`–`<h6>` block as a heading before visual scoring. | A publisher may misuse an `h` tag, but without stronger source evidence Echo preserves that explicit semantic choice. Reader heading cards and narration outlines can now recognize the section; source text and block identity stay intact. |
| Prose paragraphs beginning with “Part” or “Chapter,” and long all-caps paragraphs with a rare CSS class, were promoted to headings. | Exact publisher TOC labels remain authoritative. Other inferred headings use a conservative length and period guard, numbered or short title-shaped Chapter/Part cues, and the existing CSS/visual score. | Concise printed labels with Arabic, Roman, or spelled-out numbers, colon-separated numbers, and long unpunctuated TOC labels remain eligible. A split printed title can keep its short Chapter continuation as a heading without merging blocks. Prose stays in the reader's paragraph flow and retains its narration text and alignment anchor. |
| An image nested inside `<h1>` flushed the block tag; the final text of the same explicit heading then scored as a paragraph. | `XHTMLBlockDelegate` records the closing `h` element as the heading's source tag, even if an image flushed intermediate state. | The image stays a separate block and existing block boundaries remain intact. This corrects the final text's heading kind without moving source anchors or changing narration text. |

These are classification rules only. They do not suppress front matter, notes,
captions, or narration. The changed path does not split or join blocks, alter
their text, or rewrite pronunciation spans. Synthetic-fixture tests assert
ordered text, block IDs, source anchor IDs, and the heading marker.

## Evaluation

The source-heading check matches normalized XHTML `<h1>`–`<h6>` text to Echo's
imported blocks in the same spine item. It is a mechanical classification check,
not a whole-book accuracy estimate. The block comparison uses portable block IDs
and checks text, reading sequence, chapter index, word count, and image name.

| Measure | Development | Held out |
| --- | ---: | ---: |
| Imported / selected books | 299 / 300 | 60 / 60 |
| Paired blocks | 722,916 | 143,791 |
| Source headings matched in well-formed XHTML | 28,511 | 6,170 |
| Matched source headings emitted as paragraphs, baseline → updated | 261 → 0 | 12 → 0 |
| Block kind changes, paragraph → heading | 310 | 24 |
| Block kind changes, heading → paragraph | 150 | 43 |
| Added or removed block IDs | 0 | 0 |
| Changed text, reading sequence, word count, or image name | 0 | 0 |
| Changed chapter indices | 0 | 1 |

The one held-out chapter-index change is a long copyright paragraph containing
a chapter reference. It moves from chapter 10 to chapter 9 when its erroneous
heading classification is removed. Source inspection confirmed a paragraph tag
and prose content. No held-out example was used for further tuning.

Manual inspection covered representative false headings, explicit headings,
counterexamples such as printed chapter labels, and six imports that appeared
clean in the mechanical scan. This supports the rules above; it does not certify
all 359 imported books. We also scanned source features rather than assuming an
import success meant correct parsing: 179 books have nested NCX TOCs, 56 have
nested EPUB 3 navigation, 46 mark front matter, 84 mark body matter, 43 mark back
matter, 22 contain explicit footnote semantics, 18 contain figure captions,
131 contain tables, and five contain `<pre>` code blocks. Existing TOC, front
matter, image, code, and anchor tests passed. Those other categories were not
given a corpus-wide correctness score.

One development archive fails ZIP decompression in the source file itself;
that is a source-archive defect. The independent Python XML source scan could
not parse 614 XHTML files across 12 development books, mostly because they use
HTML named entities without XML declarations. Echo still imported those books;
the source-heading metric excludes those XHTML files. Tables remain flattened
because Echo has no table block type, and note semantics are not a separate
block kind. In one sampled code-heavy book, some `<figcaption>` text is retained
as a narration cue rather than reader-visible caption text. No rule here deletes
or suppresses that content. These limitations remain open.

Local verification: the Release `echo-cli` build passed, and 74 focused tests
across ten EPUB suites passed, including import parity, TOC hierarchy, chaptering,
front matter, images, code, text normalization, pronunciation, and source
anchors. A broader `make test` run was interrupted after more than ten minutes
of CPU time in the unchanged pronunciation audit pack's validation path; it did
not produce a completion result. Hosted CI is a separate gate.

## Reproduction

Keep the manifest and outputs on a private volume. The manifest is a JSON list
of `{ "id": "<SHA-256 prefix>", "path": "<archive>", "set": "development|held_out" }`
objects. Optional OPF and corpus metadata fields enable additional composition
counts. The saved baseline binary was built from `1f13f927`; rebuild the current
binary with `make echo-cli` through the repository's Apple build-slot wrapper.

```bash
python3 Tools/EPUBAudit/evaluate.py profile --manifest "$PRIVATE_MANIFEST" --out "$PRIVATE_PROFILE"
python3 Tools/EPUBAudit/evaluate.py run --manifest "$PRIVATE_MANIFEST" --binary "$BASELINE_CLI" --out "$PRIVATE_BASELINE"
python3 Tools/EPUBAudit/evaluate.py run --manifest "$PRIVATE_MANIFEST" --binary "$UPDATED_CLI" --out "$PRIVATE_UPDATED"
python3 Tools/EPUBAudit/evaluate.py compare --manifest "$PRIVATE_MANIFEST" --before "$PRIVATE_BASELINE" --after "$PRIVATE_UPDATED" --out "$PRIVATE_COMPARISON"
```

The evaluator can be rerun after a transient process failure; existing valid
exports are retained and failed entries are retried. Outputs contain private
book text and should remain outside the repository. The comparison prints only
aggregate counts. Image asset directories include a transient import UUID, so
the comparison checks image names at stable block IDs rather than absolute
temporary paths.
