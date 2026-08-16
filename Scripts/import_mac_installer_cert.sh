#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# One-time bootstrap: put the "Mac Installer Distribution" certificate into the
# fastlane match repository so CI can sign the macOS .pkg.
#
# WHY THIS EXISTS
# ---------------
# A Mac App Store submission needs TWO certificates. "Apple Distribution" signs
# the .app (and is shared with iOS), but the store accepts an *installer
# package*, and that .pkg is signed by a separate certificate type: "Mac
# Installer Distribution" — shown in Keychain Access as "3rd Party Mac Developer
# Installer". iOS never needs it, so Echo's iOS-first match setup stored only
# Apple Distribution and every macOS export died at the last step with:
#
#     error: exportArchive No signing certificate "Mac Installer Distribution" found
#
# Apple never re-issues a private key, so the certificate cannot simply be
# re-downloaded on CI — it has to be imported into the match repo together with
# the key that created it. That is what this script does, once.
#
# WHAT IT DELIBERATELY DOES NOT DO
# --------------------------------
# It does not mint a new certificate. Do NOT "fix" this by running
#   fastlane match --additional_cert_types mac_installer_distribution --readonly false
# to seed the repo: match/generator.rb passes `force: true` to `cert`, which
# skips the reuse check and always creates a BRAND NEW certificate, leaving the
# working one you already have as an orphan. (Echo has been bitten by orphaned
# certificates before — see ARCHITECTURE.md.) Nor should you run
#   fastlane match --type mac_installer_distribution
# which looks right, is accepted, and silently produces a duplicate *Apple
# Distribution* certificate instead: Generator only forwards the specific cert
# type for developer_id_application, so `cert` falls through to its default.
#
# USAGE
#     Scripts/import_mac_installer_cert.sh
#
# Re-running it after success is a no-op that reports the certificate is already
# stored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_CN_PREFIX="3rd Party Mac Developer Installer"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/echo-mac-installer-cert.XXXXXX")"
DER_CERT="$WORK_DIR/mac_installer.cer"
P12_PATH="$WORK_DIR/mac_installer.p12"

# The private key never outlives the script, whatever happens.
cleanup() {
  if [[ -d "$WORK_DIR" ]]; then
    find "$WORK_DIR" -type f -exec rm -f {} + 2>/dev/null || true
    rmdir "$WORK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

step()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$1"; }
die()   { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── 1. Preflight ────────────────────────────────────────────────────────────
step "Checking prerequisites"

[[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."

cd "$REPO_ROOT"

if [[ ! -f fastlane/api_key.json ]]; then
  die "fastlane/api_key.json not found in $REPO_ROOT.
    match import needs it to look the certificate up in the Developer portal.
    Run this from the canonical checkout (~/Developer/Echo), not a worktree that
    lacks the git-ignored key file."
fi
ok "App Store Connect API key present"

if [[ -z "${MATCH_PASSWORD:-}" ]]; then
  if [[ -f .env ]] && grep -q '^MATCH_PASSWORD=' .env; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
    ok "MATCH_PASSWORD loaded from .env"
  else
    die "MATCH_PASSWORD is not set and .env does not define it.
    It is the passphrase for the match certificates repo. Export it and re-run."
  fi
else
  ok "MATCH_PASSWORD set in the environment"
fi

# Echo has lost a certificate to this exact trap: macOS system Ruby links
# LibreSSL, under which match's OpenSSL::Cipher encryption fails SILENTLY — the
# cert is created in the portal but never lands in the repo.
RUBY_SSL="$(ruby -ropenssl -e 'print OpenSSL::OPENSSL_VERSION' 2>/dev/null || echo 'unknown')"
case "$RUBY_SSL" in
  OpenSSL*) ok "Ruby links $RUBY_SSL" ;;
  *) die "Ruby links '$RUBY_SSL', not OpenSSL.
    match's repo encryption fails SILENTLY under LibreSSL (macOS system Ruby
    2.6): the certificate gets created but is never committed. Activate rbenv
    first:  eval \"\$(rbenv init - zsh)\"" ;;
esac

IDENTITY_LINE="$(security find-identity -v | grep "$CERT_CN_PREFIX" | head -1 || true)"
[[ -n "$IDENTITY_LINE" ]] || die "No \"$CERT_CN_PREFIX\" identity in your keychain.
    This script imports a certificate you ALREADY have. If you genuinely have
    none, create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +
    ▸ Mac Installer Distribution, then re-run."
CERT_CN="$(sed -E 's/.*"(.*)".*/\1/' <<<"$IDENTITY_LINE")"
ok "Found identity: $CERT_CN"

# ── 2. Is it already stored? ────────────────────────────────────────────────
step "Checking whether the match repo already has it"

GIT_URL="$(sed -nE 's/^git_url\("(.*)"\).*/\1/p' fastlane/Matchfile)"
[[ -n "$GIT_URL" ]] || die "Could not read git_url from fastlane/Matchfile."

PROBE_DIR="$WORK_DIR/probe"
if git clone --quiet --depth 1 "$GIT_URL" "$PROBE_DIR" 2>/dev/null; then
  if [[ -n "$(find "$PROBE_DIR/certs/mac_installer_distribution" -name '*.p12' 2>/dev/null)" ]]; then
    ok "Already present — nothing to do."
    printf '\n    %s\n' "$(cd "$PROBE_DIR" && git ls-files certs/mac_installer_distribution/)"
    exit 0
  fi
  ok "Not present yet (expected) — continuing"
else
  warn "Could not clone $GIT_URL to pre-check; continuing anyway"
fi

# ── 3. Export the certificate as DER ────────────────────────────────────────
# TRAP 1: match compares Base64(raw file bytes) against the portal's stored
# certificateContent, which is DER. `security find-certificate -p` emits PEM,
# whose bytes never match — the import fails with "the certificate contents did
# not match with any available on the Developer Portal" and no hint why.
step "Exporting the certificate (DER)"

security find-certificate -c "$CERT_CN_PREFIX" -p > "$WORK_DIR/mac_installer.pem"
openssl x509 -in "$WORK_DIR/mac_installer.pem" -inform PEM -outform DER -out "$DER_CERT"
ok "DER certificate written ($(wc -c < "$DER_CERT" | tr -d ' ') bytes)"
openssl x509 -in "$DER_CERT" -inform DER -noout -subject -dates | sed 's/^/    /'

# ── 4. Export the private key ───────────────────────────────────────────────
# `security export` cannot filter to a single identity, so exporting just this
# one is a Keychain Access operation. It also needs your authorisation, which is
# a GUI prompt by design — a script must not be able to silently exfiltrate a
# signing key.
step "Exporting the private key (.p12) — manual step"

cat <<INSTRUCTIONS

    Keychain Access is about to open. Export the identity as a .p12:

      1. Select the "login" keychain, then the "My Certificates" category.
      2. Find:  $CERT_CN
         (its disclosure triangle must show a private key underneath —
          if it does not, this Mac does not hold the key and cannot be used)
      3. Right-click it ▸ Export "…"
      4. File Format: Personal Information Exchange (.p12)
      5. Save it as:  $P12_PATH
      6. When asked for a password, LEAVE BOTH FIELDS EMPTY and press Return.

         ⚠️  The empty password is not optional. match imports the key on CI with
             \`security import -P ''\` (hardcoded in match/utils.rb). A protected
             .p12 works on your Mac and then fails only on CI.

      7. Enter your login password if macOS asks to allow the export.

INSTRUCTIONS

open -a "Keychain Access" || warn "Could not launch Keychain Access; open it manually."
printf '    Waiting for %s ... (Ctrl-C to abort)\n' "$P12_PATH"
while [[ ! -s "$P12_PATH" ]]; do sleep 2; done
sleep 1
ok "Found $(wc -c < "$P12_PATH" | tr -d ' ') byte .p12"

# ── 5. Verify the .p12 before trusting it ───────────────────────────────────
# TRAP 2 caught here rather than three weeks later on a red CI run.
step "Verifying the .p12"

p12_opens_without_password() {
  openssl pkcs12 -in "$P12_PATH" -passin pass: -nokeys -noout 2>/dev/null ||
    openssl pkcs12 -in "$P12_PATH" -passin pass: -nokeys -noout -legacy 2>/dev/null
}
p12_contains_key() {
  openssl pkcs12 -in "$P12_PATH" -passin pass: -nocerts -noout 2>/dev/null ||
    openssl pkcs12 -in "$P12_PATH" -passin pass: -nocerts -noout -legacy 2>/dev/null
}

p12_opens_without_password || die "The .p12 is password-protected (or unreadable).
    match imports it on CI with an EMPTY password, so this would break the build
    in a way that only shows up on CI. Re-export it and leave both password
    fields blank."
ok "Opens with an empty password (what CI requires)"

p12_contains_key || die "The .p12 contains no private key.
    You exported the certificate only. Export the identity row that has a
    private key nested under it."
ok "Contains a private key"

# ── 6. Import into the match repo ───────────────────────────────────────────
# `fastlane match import` takes its three paths from interactive prompts (this
# version accepts no path flags), so the answers are fed on stdin. The third
# answer is deliberately blank: an installer certificate has no provisioning
# profile, and match would file one under "Unknown_…" if given one.
step "Importing into the match repo"

if ! printf '%s\n%s\n\n' "$DER_CERT" "$P12_PATH" | \
  bundle exec fastlane match import \
    --type mac_installer_distribution \
    --git_url "$GIT_URL" \
    --api_key_path fastlane/api_key.json
then
  # match compares strict_encode64(this file's bytes) against the portal's
  # stored certificateContent and, on any difference, says only "the certificate
  # contents did not match with any available on the Developer Portal" — the
  # same sentence whether the file is the wrong encoding, the wrong certificate,
  # or from a different Apple account. Step 3 already rules out the encoding, so
  # spell out what is actually left.
  die "match import failed.

    If it said the certificate contents did not match:
      - This certificate is DER (step 3 converted it), so encoding is not the
        cause. The likely causes are that the certificate is not in the same
        Apple team as fastlane/api_key.json, or that it has been revoked in the
        Developer portal. Check it at
        https://developer.apple.com/account/resources/certificates/list
        under \"Mac Installer Distribution\".
      - Local SHA-1 for comparison with the portal listing:
        $(openssl x509 -in "$DER_CERT" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//')

    Any other message is match's own; nothing was committed, so it is safe to
    re-run this script after fixing the cause."
fi

# ── 7. Confirm it actually landed ───────────────────────────────────────────
# match's encryption has failed silently before; trust the remote, not the log.
step "Verifying the certificate reached the repo"

VERIFY_DIR="$WORK_DIR/verify"
git clone --quiet --depth 1 "$GIT_URL" "$VERIFY_DIR"
STORED="$(cd "$VERIFY_DIR" && git ls-files certs/mac_installer_distribution/ || true)"

[[ -n "$STORED" ]] || die "Import reported success but certs/mac_installer_distribution/
    is still empty on the remote. Nothing was committed — check the output above."

ok "Stored in the certificates repo:"
printf '%s\n' "$STORED" | sed 's/^/      /'

cat <<'DONE'

    Done. CI can now sign the macOS installer package.

    The next release-train run will archive the Mac app, export a signed .pkg,
    and upload it to TestFlight. To exercise it immediately:

        gh workflow run release-trains.yml -f channel=nightly

DONE
