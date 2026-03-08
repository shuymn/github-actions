#!/usr/bin/env bash
set -euo pipefail

missing=()
for cmd in base64 gh mktemp mv; do
  command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required commands: ${missing[*]}" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: place-template-files.sh TARGET_ROOT PROVIDER_REF [--overwrite-workflows] [--overwrite-renovate]

Place workflow and Renovate template files into the target repository working tree.
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi

TARGET_ROOT="$1"
PROVIDER_REF="$2"
shift 2

OVERWRITE_WORKFLOWS=false
OVERWRITE_RENOVATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --overwrite-workflows)
    OVERWRITE_WORKFLOWS=true
    shift
    ;;
  --overwrite-renovate)
    OVERWRITE_RENOVATE=true
    shift
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

TARGET_ROOT=$(cd "${TARGET_ROOT}" && pwd)
if [[ "$(git -C "${TARGET_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)" != "${TARGET_ROOT}" ]]; then
  echo "Error: repository root must point to the target repository root." >&2
  exit 1
fi

resolve_target_repo() {
  local remote_url slug
  remote_url=$(git -C "${TARGET_ROOT}" remote get-url origin 2>/dev/null || true)
  if [[ -z "${remote_url}" ]]; then
    echo "Error: target repository must have an origin remote." >&2
    exit 1
  fi

  case "${remote_url}" in
  git@github.com:*)
    slug="${remote_url#git@github.com:}"
    ;;
  ssh://git@github.com/*)
    slug="${remote_url#ssh://git@github.com/}"
    ;;
  https://github.com/*)
    slug="${remote_url#https://github.com/}"
    ;;
  *)
    echo "Error: target repository origin must point to github.com." >&2
    exit 1
    ;;
  esac

  slug="${slug%.git}"
  slug="${slug%/}"
  if [[ ! "${slug}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Error: could not derive OWNER/REPO from origin remote." >&2
    exit 1
  fi

  gh api "repos/${slug}" -q '.full_name'
}

if base64 --decode >/dev/null 2>&1 <<<""; then
  _BASE64_DECODE_FLAG="--decode"
else
  _BASE64_DECODE_FLAG="-D"
fi

decode_base64() {
  base64 "${_BASE64_DECODE_FLAG}"
}

load_source_file() {
  local path="$1"
  gh api "repos/shuymn/github-actions/contents/${path}?ref=${PROVIDER_REF}" -q '.content' | decode_base64
}

ensure_safe_destination() {
  local path="$1"
  local rel current
  rel="${path#"${TARGET_ROOT}"/}"
  current="${TARGET_ROOT}"
  IFS='/' read -r -a parts <<<"${rel}"
  for part in "${parts[@]}"; do
    current="${current}/${part}"
    if [[ -L "${current}" ]]; then
      echo "Error: refusing to write through symlinked path: ${current}" >&2
      exit 1
    fi
  done
}

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
  local content dest_path dest_dir tmp_path existed=false
  dest_path="${TARGET_ROOT}/${dest}"
  dest_dir=$(dirname "${dest_path}")
  ensure_safe_destination "${dest_dir}"
  ensure_safe_destination "${dest_path}"
  mkdir -p "${dest_dir}"
  [[ -f "${dest_path}" ]] && existed=true
  if [[ "${existed}" == true && "${overwrite}" != true ]]; then
    echo "  ${dest} (exists, skipped)"
    return 0
  fi

  content=$(load_source_file "${path}")
  if [[ "${pin}" == true ]]; then
    content=$(printf '%s' "${content}" |
      sed "s|shuymn/github-actions/.github/workflows/\([^@]*\)@main|shuymn/github-actions/.github/workflows/\1@${PROVIDER_REF}|g")
  fi

  tmp_path=$(mktemp "${dest_dir}/.$(basename "${dest_path}").tmp.XXXXXX")
  trap 'rm -f "${tmp_path}"' RETURN
  printf '%s' "${content}" >"${tmp_path}"
  mv "${tmp_path}" "${dest_path}"
  trap - RETURN
  if [[ "${overwrite}" == true && "${existed}" == true ]]; then
    echo "  ${dest} (overwritten)"
  else
    echo "  ${dest}"
  fi
}

TARGET=$(resolve_target_repo)
echo "Placing files in: ${TARGET}"

WORKFLOW_OPTS=(--pin)
[[ "${OVERWRITE_WORKFLOWS}" == true ]] && WORKFLOW_OPTS+=(--overwrite)
place_file "${WORKFLOW_OPTS[@]}" ".github/workflows/gha.yml" "templates/workflows/gha.yml"
place_file "${WORKFLOW_OPTS[@]}" ".github/workflows/renovate.yml" "templates/workflows/renovate.yml"
place_file "${WORKFLOW_OPTS[@]}" ".github/workflows/security.yml" "templates/workflows/security.yml"

RENOVATE_OPTS=()
[[ "${OVERWRITE_RENOVATE}" == true ]] && RENOVATE_OPTS+=(--overwrite)
place_file "${RENOVATE_OPTS[@]}" ".github/renovate.json" "templates/renovate.json"
