#!/bin/bash
set -euo pipefail

# =============================================================================
# generate_architecture.sh
# =============================================================================
# Scans the project's Xcode targets and Shared/ module and writes a directory
# tree into ARCHITECTURE.md. Build artifacts, asset catalogs, and media files
# are excluded so the output focuses on source code and configuration.
#
# NOTE: This script writes the auto-generated source-tree skeleton only.
# The detailed architecture notes below the tree are maintained by hand.
# Running `make architecture` will overwrite the tree sections but preserve
# any hand-written content below the `<!-- MANUAL BELOW -->` marker.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$REPO_ROOT/ARCHITECTURE.md"

EXCLUDE_DIRS=(
    "-not" "-path" "*/.build/*"
    "-not" "-path" "*/DerivedData/*"
    "-not" "-path" "*/.swiftpm/*"
    "-not" "-path" "*/xcuserdata/*"
    "-not" "-path" "*/xcshareddata/*"
    "-not" "-path" "*/Preview Content/*"
    "-not" "-path" "*/Assets.xcassets/*"
    "-not" "-path" "*/*.xcassets/*"
)

EXCLUDE_NAMES=(
    "-not" "-name" ".DS_Store"
    "-not" "-name" "*.png"
    "-not" "-name" "*.jpg"
    "-not" "-name" "*.jpeg"
    "-not" "-name" "*.heic"
    "-not" "-name" "*.heif"
    "-not" "-name" "*.mp3"
    "-not" "-name" "*.m4a"
    "-not" "-name" "*.m4b"
    "-not" "-name" "*.wav"
    "-not" "-name" "*.gif"
    "-not" "-name" "*.webp"
    "-not" "-name" "*.ttf"
    "-not" "-name" "*.otf"
    "-not" "-name" "UserInterfaceState.xcuserstate"
    "-not" "-name" "IDEWorkspaceChecks.plist"
)

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# Preserve any hand-written content below <!-- MANUAL BELOW --> so it survives
# regeneration.
MANUAL_MARKER='<!-- MANUAL BELOW -->'
MANUAL_CONTENT=""
if [[ -f "$OUTPUT" ]] && grep -qF "$MANUAL_MARKER" "$OUTPUT"; then
    MANUAL_CONTENT="$(sed -n "/$MANUAL_MARKER/,\$p" "$OUTPUT" | tail -n +2)"
fi

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
cat > "$OUTPUT" << 'HEADER'
# Architecture Overview

<!-- ⚠️  AUTO-GENERATED — do not edit directly. -->
<!-- Regenerate with: `make architecture`                        -->

HEADER

printf "**Last generated:** %s\n\n" "$TIMESTAMP" >> "$OUTPUT"

cat >> "$OUTPUT" << 'INTRO'
This document maps the source-tree layout of the Xcode targets and Shared/
module in the Echo: Audiobook Study Player project. Folders are shown in the order
returned by the filesystem; only source, configuration, and metadata files
are included (build artifacts, asset catalogs, and media files are filtered
out).

---

INTRO

# -----------------------------------------------------------------------------
# Per-target tree helper
# -----------------------------------------------------------------------------
generate_tree() {
    local label="$1"
    local path="$2"

    printf "## %s\n\n" "$label" >> "$OUTPUT"
    printf '```\n' >> "$OUTPUT"

    if [[ -d "$path" ]]; then
        (
            cd "$path"
            find . -type f \
                "${EXCLUDE_DIRS[@]}" \
                "${EXCLUDE_NAMES[@]}" \
                -print \
                | sort \
                | sed 's|^\./||'
        ) >> "$OUTPUT"
    else
        echo "(directory not found — skipped)" >> "$OUTPUT"
    fi

    printf '```\n\n' >> "$OUTPUT"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
generate_tree "EchoCore (iOS)"                        "$REPO_ROOT/EchoCore"
generate_tree "Echo: Audiobook Study Player macOS"    "$REPO_ROOT/Echo: Audiobook Study Player macOS"
generate_tree "Echo: Audiobook Study Player Watch App" "$REPO_ROOT/Echo: Audiobook Study Player Watch App"
generate_tree "Shared (cross-target)"                  "$REPO_ROOT/Shared"
generate_tree "Widget Extension"                       "$REPO_ROOT/Echo: Audiobook Study Player Widget"

# -----------------------------------------------------------------------------
# Re-append preserved manual content
# -----------------------------------------------------------------------------
if [[ -n "$MANUAL_CONTENT" ]]; then
    printf '\n%s\n%s\n' "$MANUAL_MARKER" "$MANUAL_CONTENT" >> "$OUTPUT"
fi

echo "ARCHITECTURE.md generated at $OUTPUT"
