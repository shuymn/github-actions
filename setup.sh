#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
missing=()
for cmd in curl gh jq yq; do
  command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required commands: ${missing[*]}" >&2
  exit 1
fi

trap 'echo -e "\nInterrupted. State may be incomplete — re-run to resume." >&2; exit 130' INT TERM

usage() {
  cat <<'EOF'
Usage: setup.sh [--overwrite-workflows] [--overwrite-renovate] [TARGET]

Options:
  --skip-actions-settings Skip GitHub Actions permission settings.
  --overwrite-workflows  Overwrite existing workflow files.
  --overwrite-renovate   Overwrite an existing .github/renovate.json.
  -h, --help             Show this help.
EOF
}

SKIP_ACTIONS_SETTINGS=false
OVERWRITE_WORKFLOWS=false
OVERWRITE_RENOVATE=false
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --skip-actions-settings)
    SKIP_ACTIONS_SETTINGS=true
    shift
    ;;
  --overwrite-workflows)
    OVERWRITE_WORKFLOWS=true
    shift
    ;;
  --overwrite-renovate)
    OVERWRITE_RENOVATE=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
  *)
    if [[ -n "${TARGET}" ]]; then
      echo "Unexpected extra argument: $1" >&2
      usage >&2
      exit 1
    fi
    TARGET="$1"
    shift
    ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Unexpected extra argument: $1" >&2
  usage >&2
  exit 1
fi

TARGET="${TARGET:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
MAIN_SHA=$(gh api repos/shuymn/github-actions/commits/main -q .sha)
RAW_BASE="https://raw.githubusercontent.com/shuymn/github-actions/${MAIN_SHA}"

if [[ "${TARGET}" == */* ]]; then
  BASE_PATH="/repos/${TARGET}"
else
  BASE_PATH="/orgs/${TARGET}"
fi

if [[ "${SKIP_ACTIONS_SETTINGS}" == true ]]; then
  echo "Skipping GitHub Actions permission settings."
else
  # -------------------------------------------------------------------------
  # Allowed actions
  # -------------------------------------------------------------------------
  POLICY_URL="${RAW_BASE}/templates/allowed-actions.yml"
  POLICY=$(curl -fsSL --proto '=https' --tlsv1.2 "${POLICY_URL}")
  REQUIRED_PATTERNS=$(printf '%s' "${POLICY}" | yq -o=json '.patterns_allowed')

  already_configured() {
    local perms
    perms=$(gh api "${BASE_PATH}/actions/permissions" 2>/dev/null) || return 1
    printf '%s' "${perms}" | jq -e '.sha_pinning_required == true' >/dev/null 2>&1 || return 1
    gh api "${BASE_PATH}/actions/permissions/selected-actions" 2>/dev/null |
      jq -e --argjson required "${REQUIRED_PATTERNS}" '
          . as $cur |
          .github_owned_allowed == true and
          .verified_allowed == false and
          ($required | all(. as $p | ($cur.patterns_allowed | any(. == $p))))
        ' >/dev/null 2>&1
  }

  set +e
  already_configured
  configured=$?
  set -e
  if [[ "${configured}" -eq 0 ]]; then
    echo "Allowed actions already configured, skipping."
  else
    echo "Configuring allowed actions for: ${TARGET}"

    gh api -X PUT "${BASE_PATH}/actions/permissions" \
      -F enabled=true \
      -f allowed_actions=selected \
      -F sha_pinning_required=true

    existing=$(gh api "${BASE_PATH}/actions/permissions/selected-actions" 2>/dev/null || echo '{}')
    policy_json=$(printf '%s' "${POLICY}" | yq -o=json) || exit 1
    merged=$(jq -n \
      --argjson policy "${policy_json}" \
      --argjson existing "${existing}" '
        $policy + {
          patterns_allowed: (
            ($existing.patterns_allowed // []) + $policy.patterns_allowed | unique
          )
        }
      ')
    printf '%s' "${merged}" |
      gh api -X PUT "${BASE_PATH}/actions/permissions/selected-actions" --input -
  fi
fi

# ---------------------------------------------------------------------------
# Workflow files (repository only)
# ---------------------------------------------------------------------------
if [[ "${TARGET}" != */* ]]; then
  echo "Done."
  exit 0
fi

place_file() {
  local pin=false
  local overwrite=false
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
    --pin)
      pin=true
      shift
      ;;
    --overwrite)
      overwrite=true
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
  if [[ "${pin}" == true ]]; then
    content=$(printf '%s' "${content}" |
      sed "s|shuymn/github-actions/.github/workflows/\([^@]*\)@main|shuymn/github-actions/.github/workflows/\1@${MAIN_SHA}|g")
  fi
  encoded=$(printf '%s' "${content}" | base64 | tr -d '\n')
  sha=$(gh api "/repos/${TARGET}/contents/${dest}" -q '.sha' 2>/dev/null || true)
  if [[ -n "${sha}" && "${overwrite}" != true ]]; then
    echo "  ${dest} (exists, skipped)"
    return 0
  fi
  local action=add
  [[ -n "${sha}" ]] && action=update
  local args=(-X PUT "/repos/${TARGET}/contents/${dest}"
    -f "message=chore: ${action} ${dest}"
    -f "content=${encoded}")
  [[ -n "${sha}" ]] && args+=(-f "sha=${sha}")
  gh api "${args[@]}" >/dev/null
  if [[ -n "${sha}" ]]; then
    echo "  ${dest} (overwritten)"
  else
    echo "  ${dest}"
  fi
}

echo "Placing files in: ${TARGET}"

workflow_args=(--pin)
renovate_args=()
[[ "${OVERWRITE_WORKFLOWS}" == true ]] && workflow_args+=(--overwrite)
[[ "${OVERWRITE_RENOVATE}" == true ]] && renovate_args+=(--overwrite)

place_file "${workflow_args[@]}" ".github/workflows/gha.yml" "templates/workflows/gha.yml"
place_file "${workflow_args[@]}" ".github/workflows/renovate.yml" "templates/workflows/renovate.yml"
place_file "${workflow_args[@]}" ".github/workflows/security.yml" "templates/workflows/security.yml"
place_file "${renovate_args[@]}" ".github/renovate.json" "templates/renovate.json"

echo "Done."
