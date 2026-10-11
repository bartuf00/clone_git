# Refork action

This composite action creates a standalone repository by mirroring an upstream
repository, installs a scheduled synchronization workflow, and optionally
uploads a release asset. It uses a mirror rather than GitHub's fork API because
there is no supported API to detach a fork into a standalone repository.

## Requirements

Provide a personal access token (`token`) in `PAT_TOKEN`. The token needs
`repo` (or `public_repo` for public-only repositories) and `workflows: write`
permission so the action can create the repository and install its workflow.
`GITHUB_TOKEN` cannot create repositories and is not a replacement for this
token.

## Inputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `source_repo_url` | yes | — | Upstream URL or `owner/repo`. |
| `target_repo` | yes | — | New repository as `owner/name`. |
| `visibility` | no | `private` | `private` or `public`. |
| `sync_cron` | no | `0 4 * * *` | Five-field synchronization cron. |
| `sync_strategy` | no | `ff-only` | `ff-only`, `merge`, or `rebase`. |
| `upstream_branch` | no | `main` | Upstream branch to fetch. |
| `target_branch` | no | `main` | Target branch to update. |
| `release_tag` | no | empty | If non-empty, create/use this release tag. |
| `release_asset_path` | no | empty | File to upload to that release. |
| `token` | yes | — | PAT used for repository and workflow operations. |

## Usage

```yaml
steps:
  - uses: ./refork-action
    with:
      source_repo_url: https://github.com/example/upstream.git
      target_repo: example/standalone-project
      token: ${{ secrets.PAT_TOKEN }}
      upstream_branch: main
      target_branch: main
```

The synchronization workflow is generated at
`.github/workflows/upstream-sync.yml` in the target checkout and uses the
repository's `sync-upstream.sh` runtime semantics for branch and strategy
selection. A release is only
processed when `release_tag` is non-empty; `release-asset.sh` creates the
release if needed and uploads the requested asset, skipping an identical asset.

## Local checks

From this directory, run the Bats tests (if Bats is installed), shell syntax
checks, and dry-run rendering:

```sh
bats tests
for script in scripts/*.sh; do sh -n "$script"; done
scripts/install-sync-workflow.sh --dry-run /tmp/target https://github.com/example/upstream.git '0 4 * * *' ff-only main main
```

The dry-run output should contain no `__UPSTREAM_URL__`, `__CRON__`,
`__STRATEGY__`, `__UPSTREAM_BRANCH__`, or `__TARGET_BRANCH__` placeholders.
