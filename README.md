# github-actions

Personal collection of reusable GitHub Actions workflows and shared [Renovate](https://docs.renovatebot.com/) configuration preset.

> [!WARNING]
> This is a personal repository. Use at your own risk.

## Setup

Configure a repository for use with this project. Run it from the target repository root so local workflow changes can be reflected in GitHub Actions settings before push.

> [!WARNING]
> It modifies the target repository's GitHub Actions permission settings via the GitHub API and writes workflow files locally in your working tree.

- Configure allowed GitHub Actions (SHA pinning required, selected actions only)
- Place workflow files (`.github/workflows/gha.yml`, `renovate.yml`, `security.yml`) with refs pinned to the current commit when they do not already exist
- Place `.github/renovate.json` when it does not already exist

**Requirements:** `gh`, `jq`, `yq`

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shuymn/github-actions/main/setup.sh | bash -s -- [OPTIONS]
```

Available options:

- `--only-actions-settings`: Run only GitHub Actions permission settings sync
- `--skip-actions-settings`: Skip GitHub Actions permission settings
- `--overwrite-workflows`: Overwrite existing workflow files
- `--overwrite-renovate`: Overwrite an existing `.github/renovate.json`

## Composite Actions

### setup-task

Install [go-task/task](https://github.com/go-task/task) with caching.

```yaml
- uses: shuymn/github-actions/.github/actions/setup-task@main
  with:
    version: v3.49.0 # optional
```

Generate a SHA-pinned snippet and copy to clipboard:

```bash
yq -n '.[0].uses = "shuymn/github-actions/.github/actions/setup-task@'"$(gh api repos/shuymn/github-actions/commits/main -q .sha)"'"' | tee /dev/stderr | pbcopy
```
