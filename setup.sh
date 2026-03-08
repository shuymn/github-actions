#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
missing=()
for cmd in curl gh jq yq; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required commands: ${missing[*]}" >&2
  exit 1
fi

trap 'echo -e "\nInterrupted. State may be incomplete — re-run to resume." >&2; exit 130' INT TERM

TARGET="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
MAIN_SHA=$(gh api repos/shuymn/github-actions/commits/main -q .sha)
RAW_BASE="https://raw.githubusercontent.com/shuymn/github-actions/${MAIN_SHA}"

if [[ "$TARGET" == */* ]]; then
  BASE_PATH="/repos/${TARGET}"
else
  BASE_PATH="/orgs/${TARGET}"
fi

# ---------------------------------------------------------------------------
# Allowed actions
# ---------------------------------------------------------------------------
POLICY_URL="${RAW_BASE}/templates/allowed-actions.yml"
POLICY=$(curl -fsSL --proto '=https' --tlsv1.2 "$POLICY_URL")
REQUIRED_PATTERNS=$(printf '%s' "$POLICY" | yq -o=json '.patterns_allowed')

already_configured() {
  local perms
  perms=$(gh api "${BASE_PATH}/actions/permissions" 2>/dev/null) || return 1
  printf '%s' "$perms" | jq -e '.sha_pinning_required == true' >/dev/null 2>&1 || return 1
  gh api "${BASE_PATH}/actions/permissions/selected-actions" 2>/dev/null |
    jq -e --argjson required "${REQUIRED_PATTERNS}" '
        . as $cur |
        .github_owned_allowed == true and
        .verified_allowed == false and
        ($required | all(. as $p | ($cur.patterns_allowed | any(. == $p))))
      ' >/dev/null 2>&1
}

if already_configured; then
  echo "Allowed actions already configured, skipping."
else
  echo "Configuring allowed actions for: ${TARGET}"

  gh api -X PUT "${BASE_PATH}/actions/permissions" \
    -F enabled=true \
    -f allowed_actions=selected \
    -F sha_pinning_required=true

  existing=$(gh api "${BASE_PATH}/actions/permissions/selected-actions" 2>/dev/null || echo '{}')
  merged=$(jq -n \
    --argjson policy "$(printf '%s' "$POLICY" | yq -o=json)" \
    --argjson existing "$existing" '
      $policy + {
        patterns_allowed: (
          ($existing.patterns_allowed // []) + $policy.patterns_allowed | unique
        )
      }
    ')
  printf '%s' "$merged" |
    gh api -X PUT "${BASE_PATH}/actions/permissions/selected-actions" --input -
fi

# ---------------------------------------------------------------------------
# Workflow files (repository only)
# ---------------------------------------------------------------------------
if [[ "$TARGET" != */* ]]; then
  echo "Done."
  exit 0
fi

place_file() {
  local pin=false
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
    --pin)
      pin=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      return 1
      ;;
    esac
  done
  local dest="$1" path="$2"
  local content encoded sha
  content=$(curl -fsSL --proto '=https' --tlsv1.2 "${RAW_BASE}/${path}")
  if [[ "$pin" == true ]]; then
    content=$(printf '%s' "$content" |
      sed "s|shuymn/github-actions/.github/workflows/\([^@]*\)@main|shuymn/github-actions/.github/workflows/\1@${MAIN_SHA}|g")
  fi
  encoded=$(printf '%s' "$content" | base64 | tr -d '\n')
  sha=$(gh api "/repos/${TARGET}/contents/${dest}" -q '.sha' 2>/dev/null || true)
  local args=(-X PUT "/repos/${TARGET}/contents/${dest}"
    -f "message=chore: add ${dest}"
    -f "content=${encoded}")
  [[ -n "$sha" ]] && args+=(-f "sha=${sha}")
  gh api "${args[@]}" >/dev/null
  echo "  ${dest}"
}

echo "Placing files in: ${TARGET}"

place_file --pin ".github/workflows/gha.yml" "templates/workflows/gha.yml"
place_file --pin ".github/workflows/renovate.yml" "templates/workflows/renovate.yml"
place_file --pin ".github/workflows/security.yml" "templates/workflows/security.yml"
place_file ".github/renovate.json" "templates/renovate.json"

echo "Done."
