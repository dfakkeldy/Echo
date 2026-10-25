#!/usr/bin/env python3
"""Mechanical pre-commit checks for Echo's GRDB migrations.

Compares the working tree (committed branch work plus uncommitted edits) with
the branch point and reports what a reviewer would otherwise check by hand:

  🔴 duplicate identifier, shipped registration removed/renamed/reordered,
     shipped migration edited (inline body or Schema_Vxx file), new number
     that is already taken here or on origin/nightly, new numbers out of
     order, Schema_Vxx enum that is never registered, registration naming a
     missing enum, NOT NULL column added without a default, reference to an
     unknown table
  🟡 new migration without a test, destructive DDL (drop/rename)
  ⚠  new column on a table the importer or aligner fills (re-import needed)

Exit status: 0 when there are no 🔴 findings, 1 when there are, 2 on usage
errors. Run from anywhere inside the Echo repo:

  python3 .claude/skills/new-schema-migration/scripts/check-migrations.py
  python3 .claude/skills/new-schema-migration/scripts/check-migrations.py --base origin/nightly
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

DBSVC = "Shared/Database/DatabaseService.swift"
DB_DIR = "Shared/Database"
TEST_DIR = "EchoTests"
# Tables the EPUB/PDF importer, transcription or aligner fill: a new column on
# one of them stays NULL for existing books until a re-import or re-align.
IMPORT_FILLED = {
    "epub_block", "epub_toc_entry", "chapter", "alignment_anchor",
    "transcription_segment", "word_timing", "pdf_block_page", "timeline_item",
}
BASE_CANDIDATES = ("origin/nightly", "nightly", "origin/main", "main")

REGISTRATION = re.compile(
    r'(?:\b\w+\.)?registerMigration\(\s*"(?P<ident>v(?P<num>\d+)_[A-Za-z0-9_]*)"')
ENUM_DECL = re.compile(r"\benum\s+Schema_V(\d+)\b")
ENUM_USE = re.compile(r"\bSchema_V(\d+)\b")
CREATE_TABLE = re.compile(r'create\(\s*table:\s*"([a-z_]+)"')
ALTER_TABLE = re.compile(r'alter\(\s*table:\s*(?:"([a-z_]+)"|(\w+)\.databaseTableName)')
ADD_COLUMN = re.compile(r"\badd\(\s*column:")
REFERENCES = re.compile(r'\.references\(\s*"([a-z_]+)"')
DESTRUCTIVE = re.compile(r"\b(drop\(\s*(?:table|column|index):|rename\(\s*(?:table|column):)")


@dataclass
class Registration:
    ident: str
    num: int
    body: str  # comment-free, whitespace-collapsed source of this registration


# ---------------------------------------------------------------- utilities

def git(root: Path, *args: str) -> str | None:
    result = subprocess.run(["git", "-C", str(root), *args],
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def strip_comments(src: str) -> str:
    """Remove // and /* */ comments, leaving string literals intact."""
    out, i, n = [], 0, len(src)
    in_string = False
    while i < n:
        c = src[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j == -1 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j == -1 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def collapse(code: str) -> str:
    return " ".join(code.split())


def closure_end(code: str, start: int) -> int:
    """Index just past the closure that follows `start`, skipping string literals."""
    depth, i, in_string = 0, code.find("{", start), False
    if i == -1:
        return len(code)
    while i < len(code):
        c = code[i]
        if in_string:
            if c == "\\":
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(code)


def registrations(src: str) -> list[Registration]:
    code = strip_comments(src)
    return [Registration(m["ident"], int(m["num"]),
                         collapse(code[m.start():closure_end(code, m.end())]))
            for m in REGISTRATION.finditer(code)]


def schema_files(root: Path, ref: str | None) -> dict[int, tuple[str, str]]:
    """Map Schema_V number -> (path, source) at `ref`, or the working tree if None."""
    found: dict[int, tuple[str, str]] = {}
    if ref is None:
        paths = [str(p.relative_to(root)) for p in (root / DB_DIR).rglob("Schema_V*.swift")]
    else:
        listing = git(root, "ls-tree", "-r", "--name-only", ref, DB_DIR) or ""
        paths = [p for p in listing.splitlines() if Path(p).name.startswith("Schema_V")]
    for path in paths:
        src = read(root, ref, path)
        if src is None:
            continue
        for num in ENUM_DECL.findall(strip_comments(src)):
            found[int(num)] = (path, src)
    return found


def read(root: Path, ref: str | None, path: str) -> str | None:
    if ref is None:
        p = root / path
        return p.read_text() if p.exists() else None
    return git(root, "show", f"{ref}:{path}")


def resolve_base(root: Path, requested: str | None) -> tuple[str, str]:
    if requested:
        if git(root, "rev-parse", "--verify", "--quiet", requested + "^{commit}") is None:
            sys.exit(f"error: --base {requested} is not a commit")
        return requested, requested
    for candidate in BASE_CANDIDATES:
        if git(root, "rev-parse", "--verify", "--quiet", candidate + "^{commit}"):
            merge_base = (git(root, "merge-base", "HEAD", candidate) or "").strip()
            if merge_base:
                return merge_base, f"merge-base with {candidate}"
    return "HEAD", "HEAD"


def new_code_segments(reg_bodies: list[str], new_files: list[str]) -> list[str]:
    return reg_bodies + [collapse(strip_comments(src)) for src in new_files]


def add_column_statements(code: str) -> list[tuple[str | None, str]]:
    """(table, statement) for every add(column:) inside an alter(table:) block."""
    statements = []
    for alter in ALTER_TABLE.finditer(code):
        table = alter.group(1) or alter.group(2)
        start = code.find("{", alter.end())
        if start == -1:
            continue
        depth, end = 0, start
        for end in range(start, len(code)):
            if code[end] == "{":
                depth += 1
            elif code[end] == "}":
                depth -= 1
                if depth == 0:
                    break
        block = code[start + 1:end]
        pieces = ADD_COLUMN.split(block)
        for piece in pieces[1:]:
            stmt = re.split(r"\b\w+\.(?:add|drop|rename)\(|\btry\b", piece)[0]
            statements.append((table, "add(column:" + stmt))
    return statements


def table_name_for_record(root: Path, record: str) -> str | None:
    for path in (root / DB_DIR).rglob("*.swift"):
        src = path.read_text()
        if re.search(rf"\bstruct\s+{re.escape(record)}\b", src):
            m = re.search(r'databaseTableName\s*=\s*"([a-z_]+)"', src)
            if m:
                return m.group(1)
    return None


# -------------------------------------------------------------------- check

def check(root: Path, base_ref: str, base_label: str, tip_ref: str | None) -> int:
    work_src = read(root, None, DBSVC)
    base_src = read(root, base_ref, DBSVC)
    if work_src is None or base_src is None:
        print(f"error: {DBSVC} not found (run inside the Echo repo)")
        return 2

    work = registrations(work_src)
    base = registrations(base_src)
    base_ids = [r.ident for r in base]
    work_ids = [r.ident for r in work]
    base_by_id = {r.ident: r for r in base}
    new = [r for r in work if r.ident not in base_by_id]

    tip_regs: list[Registration] = []
    if tip_ref:
        tip_src = read(root, tip_ref, DBSVC)
        tip_regs = registrations(tip_src) if tip_src else []
    landed = [r for r in tip_regs if r.ident not in base_by_id and r.ident not in work_ids]

    work_schema = schema_files(root, None)
    base_schema = schema_files(root, base_ref)

    blockers: list[str] = []
    warnings: list[str] = []
    notes: list[str] = []

    # Duplicate identifiers make GRDB trap at launch.
    seen: set[str] = set()
    for ident in work_ids:
        if ident in seen:
            blockers.append(f'"{ident}" is registered twice; GRDB traps on a duplicate identifier.')
        seen.add(ident)

    # Shipped registrations are append-only: same identifiers, same order, same body.
    for ident in base_ids:
        if ident not in work_ids:
            blockers.append(
                f'shipped migration "{ident}" was removed or renamed. Installs that ran it '
                "keep its row in grdb_migrations; a deliberate baseline squash also needs a "
                "repair migration (see v41) and a note in the PR.")
    kept = [i for i in work_ids if i in base_by_id]
    if kept != [i for i in base_ids if i in work_ids]:
        blockers.append("shipped migrations were reordered; registration order is execution order.")
    if new and base_ids:
        last_shipped = max((work_ids.index(i) for i in kept), default=-1)
        for reg in new:
            if work_ids.index(reg.ident) < last_shipped:
                blockers.append(f'"{reg.ident}" is inserted before shipped migrations; append it after the last one.')
    for reg in work:
        old = base_by_id.get(reg.ident)
        if old and old.body != reg.body:
            blockers.append(
                f'shipped migration "{reg.ident}" was edited in DatabaseService.swift. Installs '
                "that already ran it never see the change; put it in a new migration.")
    for num, (path, src) in sorted(work_schema.items()):
        if num in base_schema:
            old_path, old_src = base_schema[num]
            if collapse(strip_comments(old_src)) != collapse(strip_comments(src)):
                blockers.append(
                    f"shipped Schema_V{num} was edited ({path}). Installs that already ran it never "
                    "see the change; put it in a new migration.")

    # New numbers must be unused, here and on the integration branch.
    base_max = max((r.num for r in base), default=0)
    taken = {}
    for r in base:
        taken.setdefault(r.num, r.ident)
    for r in landed:
        taken.setdefault(r.num, f"{r.ident} (on {tip_ref})")
    new_nums: list[int] = []
    for reg in new:
        if reg.num in taken:
            blockers.append(f'"{reg.ident}" reuses V{reg.num}, already taken by "{taken[reg.num]}".')
        elif reg.num in new_nums:
            blockers.append(f'"{reg.ident}" reuses V{reg.num}, also used by another new migration.')
        elif reg.num < base_max:
            blockers.append(f'"{reg.ident}" (V{reg.num}) is below the current max V{base_max}.')
        if new_nums and reg.num < max(new_nums):
            blockers.append(f'"{reg.ident}" is registered after a higher new version; keep new migrations ascending.')
        new_nums.append(reg.num)

    # Every Schema_Vxx must be registered; every registered enum must exist.
    work_code = strip_comments(work_src)
    referenced = {int(n) for n in ENUM_USE.findall(work_code)}
    for _, src in work_schema.values():
        code = strip_comments(src)
        own = {int(n) for n in ENUM_DECL.findall(code)}
        referenced |= {int(n) for n in ENUM_USE.findall(code)} - own
    for num, (path, _) in sorted(work_schema.items()):
        if num not in base_schema and num not in referenced:
            blockers.append(
                f"Schema_V{num} ({path}) is never registered in DatabaseService.makeMigrator(), "
                "so it never runs.")
    for reg in new:
        for num in {int(n) for n in ENUM_USE.findall(reg.body)}:
            if num not in work_schema:
                blockers.append(f'"{reg.ident}" calls Schema_V{num}, which does not exist.')

    # DDL safety for the new code only.
    new_schema_srcs = [src for num, (_, src) in work_schema.items() if num not in base_schema]
    segments = new_code_segments([r.body for r in new], new_schema_srcs)
    known_tables = set()
    for _, src in work_schema.items():
        known_tables |= set(CREATE_TABLE.findall(src[1]))
    known_tables |= set(CREATE_TABLE.findall(work_src))
    touched_import_tables: set[str] = set()
    for code in segments:
        for table, stmt in add_column_statements(code):
            if table and not table.islower():
                table = table_name_for_record(root, table) or table
            name = re.search(r'add\(column:\s*"([a-z_0-9]+)"', stmt)
            column = name.group(1) if name else "?"
            if ".notNull()" in stmt and ".defaults(" not in stmt:
                blockers.append(
                    f"{table}.{column} is added NOT NULL with no default. SQLite rejects that on a "
                    "table that already has rows, so upgrades fail while fresh-install and "
                    "in-memory tests pass. Add .defaults(to:) or make it nullable.")
            if table in IMPORT_FILLED:
                touched_import_tables.add(table)
        for ref_table in REFERENCES.findall(code):
            if ref_table not in known_tables:
                blockers.append(f'.references("{ref_table}") names a table no migration creates.')
        for match in DESTRUCTIVE.finditer(code):
            warnings.append(f"destructive DDL `{match.group(1)}` in a new migration; check data loss and every reader of it.")

    # Tests: each new migration should have a Schema test that names it.
    changed = set((git(root, "diff", "--name-only", base_ref) or "").splitlines())
    changed |= set((git(root, "ls-files", "--others", "--exclude-standard") or "").splitlines())
    changed_tests = [p for p in changed if p.startswith(TEST_DIR + "/") and (root / p).exists()]
    for reg in new:
        needles = (reg.ident, f"SchemaV{reg.num}", f"Schema_V{reg.num}")
        if not any(any(n in p or n in (root / p).read_text() for n in needles) for p in changed_tests):
            warnings.append(f'"{reg.ident}" has no test. Add {TEST_DIR}/SchemaV{reg.num}Tests.swift.')

    for table in sorted(touched_import_tables):
        notes.append(
            f"new column on {table}: existing books keep NULL there until they are re-imported "
            "or re-aligned. Say so in the PR and changelog.")

    all_nums = [r.num for r in work] + [r.num for r in landed]
    next_free = max(all_nums, default=0) + 1

    print(f"Base: {base_ref[:12]} ({base_label})")
    print(f"Registered: {len(work)} migrations, max V{max((r.num for r in work), default=0)}; "
          f"new in this change: {', '.join(r.ident for r in new) or 'none'}")
    if landed:
        print(f"Landed on {tip_ref} since the branch point: {', '.join(r.ident for r in landed)}")
    for line in blockers:
        print(f"🔴 {line}")
    for line in warnings:
        print(f"🟡 {line}")
    for line in notes:
        print(f"⚠  {line}")
    print(f"Next free version: V{next_free}")
    print(f"Result: {'FAIL' if blockers else 'PASS'} "
          f"({len(blockers)} blocker(s), {len(warnings)} warning(s))")
    return 1 if blockers else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", help="commit to compare against (default: merge-base with origin/nightly)")
    parser.add_argument("--repo", default=".", help="path inside the Echo repo")
    args = parser.parse_args()
    top = git(Path(args.repo), "rev-parse", "--show-toplevel")
    if not top:
        print("error: not inside a git repository")
        return 2
    root = Path(top.strip())
    base_ref, label = resolve_base(root, args.base)
    tip = None
    if not args.base:
        for candidate in ("origin/nightly", "nightly"):
            if git(root, "rev-parse", "--verify", "--quiet", candidate + "^{commit}"):
                tip = candidate
                break
    return check(root, base_ref, label, tip)


if __name__ == "__main__":
    sys.exit(main())
