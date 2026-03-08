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

append_unique_line() {
  local file="$1" line="$2"
  [[ -n "${line}" ]] || return 0
  if [[ ! -f "${file}" ]] || ! grep -Fqx -- "${line}" "${file}"; then
    printf '%s\n' "${line}" >>"${file}"
  fi
}

extract_uses_from_yaml() {
  local file="$1"
  yq -r '[.. | select(has("uses")) | .uses] | .[]' "${file}" 2>/dev/null | grep -v '^---$' || true
}

normalize_pattern() {
  local uses="$1" owner="$2"
  local normalized

  normalized=$(printf '%s\n' "${uses}" | sed 's|@.*||; s|^\([^/]*/[^/]*\)/.*|\1|')
  if [[ -z "${normalized}" || "${normalized}" == .* || "${normalized}" == actions/* || "${normalized}" == "${owner}/"* ]]; then
    return 0
  fi

  printf '%s\n' "${normalized}"
}

collect_patterns_from_yaml() {
  local file="$1" owner="$2" patterns_file="$3"
  local uses_lines use pattern

  uses_lines=$(extract_uses_from_yaml "${file}")
  [[ -n "${uses_lines}" ]] || return 0

  while IFS= read -r use; do
    [[ -n "${use}" ]] || continue
    pattern=$(normalize_pattern "${use}" "${owner}")
    if [[ -n "${pattern}" ]]; then
      append_unique_line "${patterns_file}" "${pattern}"
    fi
  done <<<"${uses_lines}"
}

record_reusable_workflow_refs() {
  local file="$1" reusable_file="$2"
  local uses_lines use

  uses_lines=$(extract_uses_from_yaml "${file}")
  [[ -n "${uses_lines}" ]] || return 0

  while IFS= read -r use; do
    [[ -n "${use}" ]] || continue

    if [[ "${use}" =~ ^\./(\.github/workflows/[^@]+\.ya?ml)$ ]]; then
      append_unique_line "${reusable_file}" "local:${REPO_ROOT}/${BASH_REMATCH[1]}"
      continue
    fi

    if [[ "${use}" =~ ^([^/]+/[^/]+)/(\.github/workflows/[^@]+\.ya?ml)@(.+)$ ]]; then
      append_unique_line "${reusable_file}" "remote:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    fi
  done <<<"${uses_lines}"
}

fetch_remote_workflow() {
  local repo="$1" path="$2" ref="$3" output="$4"
  gh api -H "Accept: application/vnd.github.raw" "repos/${repo}/contents/${path}?ref=${ref}" >"${output}"
}

build_patterns_json() {
  local root="$1" owner="$2"
  (
    local -a files=()
    local tmpdir reusable_workflows_file patterns_file
    local entry kind location repo path ref

    ensure_safe_repo_path "${REPO_ROOT}/.github"
    ensure_safe_repo_path "${root}"
    ensure_safe_repo_path "${REPO_ROOT}/.github/actions"

    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir}"' EXIT
    reusable_workflows_file="${tmpdir}/reusable-workflows.txt"
    patterns_file="${tmpdir}/patterns.txt"

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
      for file in "${files[@]}"; do
        collect_patterns_from_yaml "${file}" "${owner}" "${patterns_file}"
        record_reusable_workflow_refs "${file}" "${reusable_workflows_file}"
      done
    fi

    if [[ -f "${reusable_workflows_file}" ]]; then
      while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        kind="${entry%%:*}"
        location="${entry#*:}"

        case "${kind}" in
        local)
          ensure_safe_repo_path "${location}"
          if [[ -f "${location}" ]]; then
            collect_patterns_from_yaml "${location}" "${owner}" "${patterns_file}"
          fi
          ;;
        remote)
          repo="${location%%:*}"
          location="${location#*:}"
          path="${location%%:*}"
          ref="${location#*:}"
          fetch_remote_workflow "${repo}" "${path}" "${ref}" "${tmpdir}/remote-workflow.yml"
          collect_patterns_from_yaml "${tmpdir}/remote-workflow.yml" "${owner}" "${patterns_file}"
          ;;
        *) ;;
        esac
      done <"${reusable_workflows_file}"
    fi

    sort -u "${patterns_file}" 2>/dev/null | jq -nRc '
      [inputs | select(length > 0) | . + "@*"]
    '
  )
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
