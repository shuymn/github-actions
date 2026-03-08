# Actions Settings Sync Design

## Overview

This change extracts GitHub Actions permission management from `setup.sh` into an internal reusable script that computes allowed action patterns from the target repository working tree after setup files have been expanded locally. The extracted script updates repository-level Actions policy so that the configured settings match the computed source of truth exactly instead of appending missing patterns.

## Clarifications

| Question | Answer or assumption | Finalization trigger | Impact on scope/design | Status |
| --- | --- | --- | --- | --- |
| Should the new capability remain internally reusable from `setup.sh`? | Yes. The new script is an internal dependency of `setup.sh`, not a separate user workflow only. | None | The design must preserve `setup.sh` as the entry point for setup while separating policy logic. | resolved |
| Which files define allowed action usage? | Use the target repository working tree as the entrypoint: `.github/workflows/*.yml` and `.github/actions/*/action.yml`, plus first-hop reusable workflows referenced from those files. | None | The extractor follows template-owned reusable workflows without generalizing to arbitrary multi-hop workflow graphs. | resolved |
| Should Actions settings be partially merged or fully synchronized? | Synchronize the whole policy shape, including `allowed_actions=selected`, `sha_pinning_required=true`, `github_owned_allowed=true`, `verified_allowed=false`, and exact `patterns_allowed`. | None | The new script must replace append-only behavior with exact-match updates. | resolved |
| What risk tier applies? | Standard. Change rationale: Not Critical: defects are limited to repository Actions policy setup and are reversible through normal admin actions. / Not Sensitive: there is no hidden state migration, data contract, or multi-system rollback requirement. | None | Standard verification depth is acceptable. | resolved |
| How should organization targets behave after extraction? | Reject them. The target repository is derived from the current repository root only. | None | The script and `setup.sh` must fail closed before any settings mutation when the current repository cannot be resolved to a GitHub repository. | resolved |

## Goals

- Extract Actions permission synchronization into a dedicated internal script.
- Make the permission script compute allowed action patterns from the target repository working tree so unpublished consumer-repository changes can be synchronized before push.
- Make the resulting GitHub Actions settings match the computed desired state exactly.
- Keep `setup.sh` responsible for orchestration and file placement only.

## Non-Goals

- Supporting workflow discovery outside `.github/workflows/*.yml`, `.github/actions/*/action.yml`, and first-hop reusable workflows referenced from them.
- Recursively resolving second-hop or deeper reusable workflow chains.
- Introducing backward-compatible merge behavior for `selected-actions`.
- Changing workflow placement semantics beyond consuming the new internal script.
- Supporting repositories without sufficient GitHub API access.
- Preserving `make generate` or `templates/allowed-actions.yml` for compatibility.
- Supporting organization-level setup through this flow.

## Decomposition Strategy

- **Split Decision**: single
- **Decision Basis**: The change centers on one cohesive boundary: CLI automation for GitHub setup. Verification remains primarily one integrated shell flow, and splitting into root/sub docs would add ceremony without clarifying ownership.

### Boundary Inventory

| Boundary | Owns Requirements/AC | Primary Verification Surface | TEMP Lifecycle Group | Parallel Stream | Depends On |
| --- | --- | --- | --- | --- | --- |
| setup orchestration | AC1, AC4 | shell CLI invocation | none | no | actions policy sync |
| actions policy sync | AC2, AC3, AC5 | shell unit/integration checks against GitHub API payload generation | none | no | none |

## Existing Codebase Constraints

| Constraint ID | Source file/test | Constraint | Impact on design | Required verification |
| --- | --- | --- | --- | --- |
| C1 | `/Users/shuymn/ghq/github.com/shuymn/github-actions/setup.sh` | `setup.sh` currently serves as the public entry point. | The new script must be callable from `setup.sh` while deriving the target repository from the current repository root instead of accepting a repository argument. | Verify repositories without a resolvable GitHub `origin` fail before any mutation and normal repositories still complete the flow. |
| C2 | `/Users/shuymn/ghq/github.com/shuymn/github-actions/setup.sh` | Current policy logic depends on generated `templates/allowed-actions.yml` and merges patterns into existing settings. | The design must remove generated-template dependence for live synchronization and replace merge behavior with exact synchronization based on the target repository working tree. | Verify resulting payload uses only locally discovered target-repository patterns and removes stale ones. |
| C3 | `/Users/shuymn/ghq/github.com/shuymn/github-actions/Makefile` | `make generate` currently derives allowed action patterns from this repository's workflow and action files. | The new script should reuse the same discovery semantics, then replace this generated path entirely as a breaking simplification. | Verify the new discovery logic covers the same inputs before removing generation-based maintenance. |
| C4 | `/Users/shuymn/ghq/github.com/shuymn/github-actions/README.md` | README documents `setup.sh` as the primary operator-facing interface. | Documentation must continue to center `setup.sh`, with the extracted script documented only as needed for maintainers or advanced usage. | Verify README remains aligned with CLI behavior and option semantics. |

## Risk Classification

| Area | Tier | Change Rationale |
| --- | --- | --- |
| Actions policy synchronization script | Standard | Not Critical: failures affect repository automation policy only and can be corrected with a rerun or manual admin update. / Not Sensitive: settings are explicit GitHub configuration, not hidden state or cross-system data. |
| `setup.sh` integration | Standard | Not Critical: failures are limited to setup orchestration in one repository or organization target. / Not Sensitive: invocation changes are local and observable through CLI output. |

## Proposed Solution

Introduce a new internal shell script dedicated to Actions permission synchronization. `setup.sh` will call this script unless `--skip-actions-settings` is set. The new script will:

1. Resolve the target repository from the current repository root and fail if it does not map cleanly to a GitHub repository.
2. Read target-repository working-tree content required to discover action usage from `.github/workflows/*.yml` and `.github/actions/*/action.yml`.
3. Parse all `uses:` references from those entrypoint files, normalize them to owner/repo patterns, exclude local actions, `actions/*`, and self-managed references for the target owner resolved dynamically at runtime.
4. When an entrypoint file references a reusable workflow, load that reusable workflow once and include the action patterns used inside it.
5. Build the desired selected-actions payload with:
   - `github_owned_allowed=true`
   - `verified_allowed=false`
   - `patterns_allowed=<normalized exact set>`
5. Apply the desired state exactly via GitHub API rather than merging with the current remote patterns.

This change removes `make generate` and `templates/allowed-actions.yml` from the setup flow entirely. Live synchronization must rely only on discovery performed against the target repository working tree after template expansion.

## Detailed Design

### Script Boundary

Add dedicated internal scripts under the repository, owned by setup automation. `setup.sh` will delegate file placement and Actions settings synchronization, while it keeps only argument parsing, repository-root validation, and orchestration. The synchronization script will resolve the target repository from the target working tree and perform all GitHub API interactions needed for permission synchronization.

### Discovery Model

The script will inspect the target repository working-tree entrypoints:

- `.github/workflows/*.yml`
- `.github/actions/*/action.yml`

The discovery rules will mirror the existing `make generate` logic for direct `uses:` values, then add one reusable-workflow expansion step:

- collect `uses:` values
- strip refs after `@`
- reduce nested action paths to `owner/repo`
- exclude local references beginning with `.`
- exclude `actions/*`
- resolve the target owner dynamically from GitHub metadata and exclude `<target-owner>/*` self-managed references
- detect first-hop reusable workflow references from the entrypoint files and inspect those referenced workflow files once
- sort and de-duplicate before submission

The script must treat the locally discovered target-repository set, augmented by first-hop reusable workflow expansion, as the complete desired `patterns_allowed` list. If a pattern exists remotely but is absent from discovery, it must be removed on synchronization.

### API Update Semantics

- the script must set `/actions/permissions` to `enabled=true`, `allowed_actions=selected`, and `sha_pinning_required=true`
- the script must set `/actions/permissions/selected-actions` to the exact desired payload without preserving remote-only patterns

### Orchestration Changes

`setup.sh` will:

- require execution from the target repository root
- derive the target repository from the current repository root and `origin` remote instead of accepting a repository argument
- place template files into the target repository working tree before synchronizing Actions settings
- replace inline Actions settings logic with a call to the extracted script
- support an Actions-settings-only mode for invoking the extracted script without placing files
- continue honoring `--skip-actions-settings`
- reject organization-like targets before any settings mutation
- use the target repository working tree as the source of truth for final permission synchronization

### Alternatives Considered

1. Keep `setup.sh` monolithic and replace the generated template with live discovery.
   This was rejected because the user explicitly wants the logic to become an independent reusable script, and keeping it inline would preserve mixed responsibilities.
2. Keep merge semantics for remote `patterns_allowed`.
   This was rejected because merge mode leaves stale permissions behind and prevents the target repository from being treated as the authoritative source of truth.
3. Continue supporting organization targets.
   This was rejected because organization-level mutation is considered too risky for this setup flow.

## Acceptance Criteria

- **AC1 / cli-contract / behavioral**: When `setup.sh` runs without `--skip-actions-settings`, the system shall delegate repository Actions permission management to the extracted internal script.
- **AC2 / cli-contract / behavioral**: When the synchronization script runs for a repository target, the system shall derive the desired allowed action patterns from `.github/workflows/*.yml` and `.github/actions/*/action.yml` in the target repository working tree, plus first-hop reusable workflows referenced from those files.
- **AC2a / behavioral**: When an entrypoint workflow references a reusable workflow, the system shall include third-party action patterns used inside that referenced reusable workflow in the desired allowlist.
- **AC3 / behavioral**: When the remote `selected-actions.patterns_allowed` contains entries not present in the discovered desired set, the system shall remove those entries by updating GitHub with the exact desired payload instead of merging.
- **AC4 / cli-contract / behavioral**: When `setup.sh` runs with `--skip-actions-settings`, the system shall not invoke the extracted synchronization script and shall continue remaining setup behavior unchanged.
- **AC5 / api-contract / behavioral**: When the synchronization script updates repository Actions settings, the system shall set `enabled=true`, `allowed_actions=selected`, `sha_pinning_required=true`, `github_owned_allowed=true`, and `verified_allowed=false` in the resulting GitHub configuration.
- **AC6 / cli-contract / behavioral**: When `setup.sh` or the synchronization script cannot derive a valid GitHub repository from the current repository root, the system shall fail before any GitHub settings mutation with a clear repository-resolution error.
- **AC7 / cli-contract / behavioral**: When `setup.sh` runs with the Actions-settings-only flag, the system shall run repository Actions permission synchronization and exit before placing workflow or Renovate files.
- **AC8 / cli-contract / behavioral**: When `setup.sh` runs in normal mode, the system shall place template files into the target repository working tree first, then synchronize Actions settings against the resulting local file set.
