#!/usr/bin/env python3
"""Run and compare private EPUB corpora through Echo's actual export-blocks CLI.

The manifest is a private JSON list of {id, path, set} objects. The archive paths,
exported book text, and per-book findings stay in the output directory. Only
aggregate counts should be copied into a public report.
"""

import argparse
import collections
import json
import re
import subprocess
import time
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ET


def corpus(path):
    records = json.loads(path.read_text())
    for record in records:
        if not all(record.get(key) for key in ("id", "path", "set")):
            raise ValueError("Every manifest row needs id, path, and set")
    if len({row["id"] for row in records}) != len(records):
        raise ValueError("Corpus IDs must be distinct")
    return records


def run(args):
    output = args.out
    output.mkdir(parents=True, exist_ok=True)
    results_path = output / "results.json"
    results = {row["id"]: row for row in json.loads(results_path.read_text())} if results_path.exists() else {}
    for record in corpus(args.manifest):
        if args.set != "all" and record["set"] != args.set:
            continue
        destination = output / f'{record["id"]}.json'
        if destination.exists():
            try:
                blocks = json.loads(destination.read_text())["blocks"]
                results[record["id"]] = {"id": record["id"], "set": record["set"], "status": "ok", "blocks": len(blocks)}
                continue
            except (OSError, ValueError, KeyError):
                destination.unlink()
        start = time.monotonic()
        try:
            completed = subprocess.run(
                [str(args.binary), "export-blocks", "--epub", record["path"], "--out", str(destination)],
                capture_output=True,
                text=True,
                timeout=args.timeout,
                check=False,
            )
            if completed.returncode == 0 and destination.exists():
                blocks = json.loads(destination.read_text())["blocks"]
                result = {"status": "ok", "blocks": len(blocks)}
            else:
                result = {"status": "error", "exit_code": completed.returncode, "detail": completed.stderr[-1200:]}
        except subprocess.TimeoutExpired:
            result = {"status": "timeout"}
        results[record["id"]] = {
            "id": record["id"], "set": record["set"],
            "seconds": round(time.monotonic() - start, 2), **result,
        }
        results_path.write_text(json.dumps(list(results.values()), indent=2))
    counts = collections.Counter(row["status"] for row in results.values())
    print(json.dumps({"processed": len(results), "statuses": dict(counts)}, sort_keys=True))


def normalized(text):
    return "".join((text or "").casefold().split())


def image_name(block):
    # In-memory imports use a new audiobook UUID, so the asset directory moves
    # between runs even when the image source and block are unchanged.
    path = block.get("imagePath")
    return Path(path).name if path else None


def local_name(element):
    return element.tag.rsplit("}", 1)[-1].lower()


def source_headings(record):
    """Yield source h1-h6 text with spine positions from well-formed XHTML."""
    with zipfile.ZipFile(record["path"]) as archive:
        opf_path = record.get("opf")
        if opf_path is None:
            container = ET.fromstring(archive.read("META-INF/container.xml"))
            opf_path = next(
                element.attrib["full-path"]
                for element in container.iter()
                if local_name(element) == "rootfile" and "full-path" in element.attrib
            )
        raw = archive.read(opf_path)
        raw = re.sub(rb"&(?!#\d+;|#x[\da-fA-F]+;|[A-Za-z][\w.:-]*;)", b"&amp;", raw)
        opf = ET.fromstring(raw)
        items = {
            element.attrib["id"]: element.attrib["href"]
            for element in opf.iter()
            if local_name(element) == "item" and "id" in element.attrib and "href" in element.attrib
        }
        spine = [items.get(element.attrib.get("idref")) for element in opf.iter() if local_name(element) == "itemref"]
        base = opf_path.rsplit("/", 1)[0] + "/" if "/" in opf_path else ""
        for spine_index, href in enumerate(spine):
            if href is None:
                continue
            try:
                root = ET.fromstring(archive.read(base + href.split("#", 1)[0]))
            except (KeyError, ET.ParseError, UnicodeError):
                continue
            for element in root.iter():
                if local_name(element) in {"h1", "h2", "h3", "h4", "h5", "h6"}:
                    text = normalized("".join(element.itertext()))
                    if text:
                        yield spine_index, text


def heading_counts(record, blocks):
    by_spine = collections.defaultdict(lambda: collections.defaultdict(set))
    for block in blocks:
        match = re.fullmatch(r"s(\d+)-b\d+", block["id"])
        if match:
            by_spine[int(match.group(1))][normalized(block["text"])].add(block["kind"])
    counts = collections.Counter()
    try:
        for spine_index, text in source_headings(record):
            counts["source_heading"] += 1
            kinds = by_spine[spine_index].get(text, set())
            if "heading" in kinds:
                counts["source_heading_preserved"] += 1
            elif kinds:
                counts["source_heading_wrong_kind"] += 1
            else:
                counts["source_heading_unmatched"] += 1
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, ET.ParseError):
        counts["source_scan_error"] += 1
    return counts


def profile(args):
    """Count source structures without exporting book text or relying on import success."""
    records = corpus(args.manifest)
    per_book = []
    for record in records:
        counts = collections.Counter()
        max_toc_depth = 0
        max_nav_depth = 0
        try:
            with zipfile.ZipFile(record["path"]) as archive:
                for name in archive.namelist():
                    lower = name.lower()
                    if lower.endswith((".xhtml", ".html", ".htm")):
                        try:
                            root = ET.fromstring(archive.read(name))
                        except (ET.ParseError, UnicodeError, ValueError):
                            counts["xhtml_not_well_formed"] += 1
                            continue
                        counts["xhtml_parsed"] += 1
                        for element in root.iter():
                            tag = local_name(element)
                            if tag in {"h1", "h2", "h3", "h4", "h5", "h6", "p", "figure", "figcaption", "img", "table", "pre", "aside", "nav"}:
                                counts[f"tag_{tag}"] += 1
                            for key, value in element.attrib.items():
                                if key.rsplit("}", 1)[-1] == "type":
                                    for term in value.split():
                                        if term in {"frontmatter", "bodymatter", "backmatter", "footnote", "endnote", "noteref", "preface", "appendix", "toc", "landmarks"}:
                                            counts[f"semantic_{term}"] += 1
                            if tag == "nav" and any(
                                key.rsplit("}", 1)[-1] == "type" and "toc" in value.split()
                                for key, value in element.attrib.items()
                            ):
                                def visit_nav(child, depth):
                                    nonlocal max_nav_depth
                                    if local_name(child) == "li":
                                        counts["nav_entries"] += 1
                                        max_nav_depth = max(max_nav_depth, depth)
                                        depth += 1
                                    for descendant in child:
                                        visit_nav(descendant, depth)

                                visit_nav(element, 1)
                    elif lower.endswith(".ncx"):
                        try:
                            root = ET.fromstring(archive.read(name))
                        except (ET.ParseError, UnicodeError, ValueError):
                            counts["ncx_not_well_formed"] += 1
                            continue
                        counts["ncx_documents"] += 1

                        def visit(element, depth):
                            nonlocal max_toc_depth
                            if local_name(element) == "navpoint":
                                counts["toc_entries"] += 1
                                max_toc_depth = max(max_toc_depth, depth)
                                depth += 1
                            for child in element:
                                visit(child, depth)

                        visit(root, 1)
        except (OSError, ValueError, zipfile.BadZipFile):
            counts["archive_read_error"] += 1
        per_book.append({"id": record["id"], "set": record["set"], "max_toc_depth": max_toc_depth, "max_nav_depth": max_nav_depth, "counts": dict(counts)})
    aggregate = {}
    for set_name in ("development", "held_out"):
        subset = [row for row in per_book if row["set"] == set_name]
        source_rows = [row for row in records if row["set"] == set_name]
        element_counts = collections.Counter()
        book_counts = collections.Counter()
        for row in subset:
            element_counts.update(row["counts"])
            book_counts.update(key for key, value in row["counts"].items() if value)
        aggregate[set_name] = {
            "books": len(subset),
            "element_counts": dict(element_counts),
            "books_with": dict(book_counts),
            "nested_ncx_books": sum(row["max_toc_depth"] > 1 for row in subset),
            "maximum_ncx_depth": max((row["max_toc_depth"] for row in subset), default=0),
            "nested_nav_books": sum(row["max_nav_depth"] > 1 for row in subset),
            "maximum_nav_depth": max((row["max_nav_depth"] for row in subset), default=0),
            "distinct_publishers": len({row["publisher"] for row in source_rows if row.get("publisher")}),
            "distinct_generators": len({row["generator"] for row in source_rows if row.get("generator")}),
            "distinct_subjects": len({row["subject"] for row in source_rows if row.get("subject")}),
            "epub_versions": dict(collections.Counter(row.get("epub_version", "unknown") for row in source_rows)),
            "image_rich_books": sum(row.get("image_count", 0) >= 30 for row in source_rows),
        }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"aggregate": aggregate, "per_book": per_book}, indent=2, sort_keys=True))
    print(json.dumps(aggregate, sort_keys=True))


def compare(args):
    summary = {}
    for set_name in ("development", "held_out"):
        totals = collections.Counter()
        transitions = collections.Counter()
        for record in corpus(args.manifest):
            if record["set"] != set_name:
                continue
            before_path = args.before / f'{record["id"]}.json'
            after_path = args.after / f'{record["id"]}.json'
            if not before_path.exists() or not after_path.exists():
                totals["missing_pair"] += 1
                continue
            before_document = json.loads(before_path.read_text())
            after_document = json.loads(after_path.read_text())
            before = before_document["blocks"]
            after = after_document["blocks"]
            if before_document["source"]["epubSHA256"] != after_document["source"]["epubSHA256"]:
                totals["source_digest_mismatch"] += 1
            totals["paired_books"] += 1
            totals["baseline_blocks"] += len(before)
            totals["updated_blocks"] += len(after)
            old = {block["id"]: block for block in before}
            new = {block["id"]: block for block in after}
            totals["added_ids"] += len(new.keys() - old.keys())
            totals["removed_ids"] += len(old.keys() - new.keys())
            for block_id in old.keys() & new.keys():
                left, right = old[block_id], new[block_id]
                if left["text"] != right["text"]:
                    totals["changed_text"] += 1
                if left["sequenceIndex"] != right["sequenceIndex"]:
                    totals["changed_sequence_index"] += 1
                if left["wordCount"] != right["wordCount"]:
                    totals["changed_word_count"] += 1
                if image_name(left) != image_name(right):
                    totals["changed_image_name"] += 1
                if left["chapterIndex"] != right["chapterIndex"]:
                    totals["changed_chapter_index"] += 1
                if left["kind"] != right["kind"]:
                    transitions[f'{left["kind"]}->{right["kind"]}'] += 1
            for prefix, blocks in (("before", before), ("after", after)):
                totals.update({f"{prefix}_{key}": value for key, value in heading_counts(record, blocks).items()})
        summary[set_name] = {"counts": dict(totals), "kind_transitions": dict(transitions)}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=2, sort_keys=True))
    print(json.dumps(summary, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    runner = subcommands.add_parser("run")
    runner.add_argument("--manifest", type=Path, required=True)
    runner.add_argument("--binary", type=Path, required=True)
    runner.add_argument("--out", type=Path, required=True)
    runner.add_argument("--set", choices=("all", "development", "held_out"), default="all")
    runner.add_argument("--timeout", type=int, default=150)
    runner.set_defaults(func=run)
    comparison = subcommands.add_parser("compare")
    comparison.add_argument("--manifest", type=Path, required=True)
    comparison.add_argument("--before", type=Path, required=True)
    comparison.add_argument("--after", type=Path, required=True)
    comparison.add_argument("--out", type=Path, required=True)
    comparison.set_defaults(func=compare)
    source_profile = subcommands.add_parser("profile")
    source_profile.add_argument("--manifest", type=Path, required=True)
    source_profile.add_argument("--out", type=Path, required=True)
    source_profile.set_defaults(func=profile)
    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
