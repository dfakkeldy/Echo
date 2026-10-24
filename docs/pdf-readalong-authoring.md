# PDF read-along authoring

Reviewed October 24, 2026. The format is defined by [`PDFReadAlongFile.swift`](../EchoCore/Services/PDFReadAlongFile.swift) and exercised by [`PDFReadAlongFileTests.swift`](../EchoTests/PDFReadAlongFileTests.swift).

Place `Title.readalong.json` beside `Title.pdf` before import. A matching file supplies narration segments in reading order and the printed rectangles for each spoken word. Echo uses it instead of PDFKit text extraction, so the author can omit running headers, page numbers, or other page furniture. iOS and macOS PDF readers use the supplied boxes for highlighting.

## Minimal example

The coordinates below illustrate a two-word paragraph on a one-page PDF; replace them with boxes measured from your document.

```json
{
  "format": "echo-pdf-readalong",
  "version": 1,
  "pdf": { "file": "Title.pdf", "pageCount": 1 },
  "segments": [
    {
      "kind": "paragraph",
      "text": "Recall matters.",
      "page": 0,
      "words": [
        { "p": 0, "r": [[54, 700, 42, 12]] },
        { "p": 0, "r": [[100, 700, 48, 12]] }
      ]
    }
  ]
}
```

## Fields and validation

- `format` must be `echo-pdf-readalong`; `version` must be `1`.
- `pdf.pageCount` must match the PDF. `pdf.file` is optional metadata; discovery uses the sidecar filename. Add `pdf.sha256`, the hex SHA-256 of the final PDF bytes, to bind the sidecar to that exact PDF. Hash comparison is case-insensitive. Without it, page count alone does not establish document identity.
- `segments` must be nonempty and ordered as narration should read. Each segment needs nonempty spoken `text`, a zero-based `page`, a `kind`, and a `words` array. `kind: "heading"` creates a heading; optional `level` defaults to 2 and is clamped to at least 1. Other kinds become ordinary text units.
- A nonempty `words` array must contain one entry per token returned by Echo's [`WordTokenizer`](../Shared/WordTokenizer.swift), in that order. Do not assume splitting on spaces matches every punctuation or Unicode case.
- Each word has optional zero-based page `p` and an array `r` of rectangles. Rectangles are `[x, y, width, height]` in **PDF page-space points, origin at bottom-left**. All four values must be finite. Keep the geometry inside the actual page; the validator checks the four-value shape and finite numbers, not every layout constraint.
- A word can have multiple rectangles, such as a line-broken word. A word with `p: null` must have `r: []`. A spoken word with no rectangles has no printed highlight. A whole segment with `words: []` is spoken without printed word boxes, useful for an exercise cue.
- Every segment page and non-null word page must be in range. A segment's words can continue onto another page.

A missing, malformed, or mismatched sidecar is logged and skipped; ordinary PDF text extraction remains the fallback. This is different from the strict rejection of invalid EPUB pronunciation metadata.

## Import and revision

Export the PDF first, measure its final layout, generate the sidecar, and add the hash last. Keep both files together. Reimport after changes so the stored blocks and `pdf_block_page.word_boxes` refresh; opening a previously imported book does not by itself replace stored mappings.

The sidecar carries **text order and page geometry**, not measured audio timing or pronunciation instructions. Narration/alignment supply timing separately. See [the manual](guides/user-manual.md#13-pdf-companion-documents) and [EPUB IPA/PLS authoring](epub-pronunciation-authoring.md) for those workflows.
