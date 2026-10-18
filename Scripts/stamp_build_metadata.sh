#!/bin/sh
set -eu

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${INFOPLIST_PATH:-}" ] || [ -z "${SRCROOT:-}" ] || [ -z "${DERIVED_FILE_DIR:-}" ]; then
  exit 0
fi

INFO_PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "${INFO_PLIST}" ]; then
  exit 0
fi

GIT_HASH="unknown"
if command -v git >/dev/null 2>&1; then
  GIT_HASH="$(git -C "${SRCROOT}" rev-parse --short=10 HEAD 2>/dev/null || true)"
  if [ -z "${GIT_HASH}" ]; then
    GIT_HASH="unknown"
  elif ! git -C "${SRCROOT}" diff-index --quiet HEAD -- 2>/dev/null; then
    GIT_HASH="${GIT_HASH}-dirty"
  fi
fi

/usr/libexec/PlistBuddy -c "Set :GitCommitHash ${GIT_HASH}" "${INFO_PLIST}" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :GitCommitHash string ${GIT_HASH}" "${INFO_PLIST}"

STAMP_FILE="${DERIVED_FILE_DIR}/build-metadata.stamp"
mkdir -p "$(dirname "${STAMP_FILE}")"
printf '%s\n' "${GIT_HASH}" > "${STAMP_FILE}"
