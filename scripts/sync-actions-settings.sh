#!/usr/bin/env bash
set -euo pipefail

export GH_PAGER=""

missing=()
for cmd in gh git jq yq; do
  command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required commands: ${missing[*]}" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: sync-actions-settings.sh [REPO_ROOT]

Synchronize repository GitHub Actions settings from the target repository
working tree.
EOF
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

REPO_ROOT="${1:-$(pwd -P)}"
REPO_ROOT=$(cd "${REPO_ROOT}" && pwd)
if [[ "$(git -C "${REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)" != "${REPO_ROOT}" ]]; then
  echo "Error: repository root must point to the target repository root." >&2
  exit 1
fi

resolve_target_repo() {
  local remote_url slug
  remote_url=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)
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

ensure_safe_repo_path() {
  local path="$1"
  local rel current
  rel="${path#"${REPO_ROOT}"/}"
  current="${REPO_ROOT}"
  IFS='/' read -r -a parts <<<"${rel}"
  for part in "${parts[@]}"; do
    current="${current}/${part}"
    if [[ -L "${current}" ]]; then
      echo "Error: refusing to read through symlinked path: ${current}" >&2
      exit 1
    fi
  done
}

build_patterns_json() {
  local root="$1" owner="$2"
  local -a files=()
  local raw_lines=""
  local patterns=""

  ensure_safe_repo_path "${REPO_ROOT}/.github"
  ensure_safe_repo_path "${root}"
  ensure_safe_repo_path "${REPO_ROOT}/.github/actions"

  if compgen -G "${root}/workflows/*.yml" >/dev/null; then
    while IFS= read -r file; do
      ensure_safe_repo_path "${file}"
      files+=("${file}")
    done < <(printf '%s\n' "${root}"/workflows/*.yml | sort || true)
  fi

  if compgen -G "${root}/actions/*/action.yml" >/dev/null; then
    while IFS= read -r file; do
      ensure_safe_repo_path "${file}"
      files+=("${file}")
    done < <(printf '%s\n' "${root}"/actions/*/action.yml | sort || true)
  fi

  if [[ ${#files[@]} -gt 0 ]]; then
    raw_lines=$(yq '[.. | select(has("uses")) | .uses] | .[]' "${files[@]}" 2>/dev/null | grep -v '^---$' || true)
  fi

  if [[ -n "${raw_lines}" ]]; then
    patterns=$(printf '%s\n' "${raw_lines}" |
      sed 's|@.*||; s|^\([^/]*/[^/]*\)/.*|\1|' |
      grep -vE '^(\.|actions/)' |
      grep -vE "^${owner}/" |
      sort -u || true)
  fi

  jq -nRc '
    [inputs | select(length > 0) | . + "@*"]
  ' <<<"${patterns}"
}

already_configured() {
  local required_patterns="$1"
  local perms current_selected

  perms=$(gh api "repos/${TARGET}/actions/permissions" 2>/dev/null) || return 1
  current_selected=$(gh api "repos/${TARGET}/actions/permissions/selected-actions" 2>/dev/null) || return 1

  jq -ne \
    --argjson required "${required_patterns}" \
    --argjson perms "${perms}" \
    --argjson current "${current_selected}" '
      ($perms.enabled == true) and
      ($perms.allowed_actions == "selected") and
      ($perms.sha_pinning_required == true) and
      ($current.github_owned_allowed == true) and
      ($current.verified_allowed == false) and
      (($current.patterns_allowed // []) == $required)
    ' >/dev/null
}

TARGET=$(resolve_target_repo)
owner="${TARGET%/*}"

required_patterns=$(build_patterns_json "${REPO_ROOT}/.github" "${owner}")

set +e
already_configured "${required_patterns}"
configured=$?
set -e
if [[ "${configured}" -eq 0 ]]; then
  echo "Allowed actions already configured, skipping."
  exit 0
fi

echo "Configuring allowed actions for: ${TARGET}"

gh api -X PUT "repos/${TARGET}/actions/permissions" \
  -F enabled=true \
  -f allowed_actions=selected \
  -F sha_pinning_required=true

jq -n \
  --argjson required "${required_patterns}" '
    {
      github_owned_allowed: true,
      verified_allowed: false,
      patterns_allowed: $required
    }
  ' |
  gh api -X PUT "repos/${TARGET}/actions/permissions/selected-actions" --input -
