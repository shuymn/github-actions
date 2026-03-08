# ADR 001: Extract Actions Settings Synchronization

- **Status**: Proposed
- **Date**: 2026-03-08

## Context

`setup.sh` currently owns both repository file placement and GitHub Actions permission management. The permission logic depends on `templates/allowed-actions.yml`, whose contents are generated from this repository by `make generate`. That makes live setup behavior repository-specific and prevents the permission updater from acting as a reusable synchronizer based on the target repository working tree after local setup expansion.

The current updater also merges missing `patterns_allowed` entries into the existing GitHub configuration. That preserves stale allowlist entries and means the target repository configuration can drift away from the workflows and composite actions actually present in the target.

## Decision

Extract GitHub Actions permission synchronization into an internal reusable script that:

- is invoked by `setup.sh`
- computes desired allowed action patterns from the target repository's local workflow and composite action files
- resolves the target repository from the target working tree and excludes self-managed references without hardcoding a specific owner
- updates GitHub Actions settings to match the computed desired state exactly

`setup.sh` remains the operator-facing entry point for setup orchestration, while the internal scripts become the source of truth for file placement and Actions policy synchronization. As a breaking simplification, `make generate` and `templates/allowed-actions.yml` are removed instead of being retained as compatibility artifacts. Organization-level targets are explicitly rejected so this flow only mutates repository-level settings, the target repository is derived from the current repository root instead of being passed as an argument, and `setup.sh` can invoke the synchronization path by itself when settings-only execution is desired. In normal mode, `setup.sh` first expands templates into the target repository working tree and then synchronizes Actions settings from that resulting local state.

## Consequences

- The setup flow becomes easier to maintain because Actions policy logic is isolated from file placement.
- Repositories configured by the script can converge on an exact allowlist based on unpublished target-repository changes instead of waiting for remote state to catch up.
- The implementation must fail closed for non-repository targets before any GitHub settings mutation.
- `templates/allowed-actions.yml` and `make generate` should be removed so the repository no longer carries a second policy derivation path.
