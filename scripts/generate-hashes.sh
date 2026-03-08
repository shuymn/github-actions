#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SH="${REPO_ROOT}/setup.sh"

hash_place=$(shasum -a 256 "${REPO_ROOT}/scripts/place-template-files.sh" | cut -d' ' -f1)
hash_sync=$(shasum -a 256 "${REPO_ROOT}/scripts/sync-actions-settings.sh" | cut -d' ' -f1)

tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT

awk \
  -v hash_place="${hash_place}" \
  -v hash_sync="${hash_sync}" '
  /^# --- BEGIN SCRIPT HASHES/ {
    print
    print "HASH_place_template_files=\"" hash_place "\""
    print "HASH_sync_actions_settings=\"" hash_sync "\""
    skip = 1
    next
  }
  /^# --- END SCRIPT HASHES/ {
    skip = 0
  }
  !skip { print }
' "${SETUP_SH}" >"${tmp}"

cp "${tmp}" "${SETUP_SH}"
