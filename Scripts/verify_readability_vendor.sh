#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
vendor_directory="$repository_root/ThirdParty/Readability"
pin_file="$vendor_directory/PIN.json"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

read -r tarball_url expected_integrity <<EOF
$(python3 - "$pin_file" <<'PY'
import json
import sys

pin = json.load(open(sys.argv[1], encoding="utf-8"))
print(pin["npmTarball"], pin["npmIntegrity"].removeprefix("sha512-"))
PY
)
EOF

tarball="$temporary_directory/readability.tgz"
curl --fail --location --silent --show-error "$tarball_url" --output "$tarball"

actual_integrity="$(openssl dgst -sha512 -binary "$tarball" | openssl base64 -A)"
if [[ "$actual_integrity" != "$expected_integrity" ]]; then
    echo "Readability npm integrity mismatch" >&2
    exit 1
fi

tar -xzf "$tarball" -C "$temporary_directory" package/Readability.js package/LICENSE.md
cmp --silent "$temporary_directory/package/Readability.js" "$vendor_directory/Readability.js"
cmp --silent "$temporary_directory/package/LICENSE.md" "$vendor_directory/LICENSE.md"

echo "Readability vendor pin verified: @mozilla/readability 0.6.0"
