# Standalone mirror action

Creates a **new**, independent GitHub repository from an upstream repository,
then commits a scheduled sync workflow and its runtime to the target. It does
not use GitHub's fork API. Branches, tags, and Git history are mirrored; issues,
pull requests, release assets, settings, and secrets are **not** copied.

Upstream **Git LFS payloads** are additionally archived into the target as
dedicated content-addressed releases (`lfs-archive/<sha256>`), one release per
object, both at provisioning time and on every scheduled sync. This uses GitHub
Release asset storage — **never** the target repository's native LFS storage,
so it consumes no target LFS quota.

## Setup

1. Use a Linux runner with Git and GitHub CLI (`ubuntu-latest` provides both).
2. Store a **classic PAT** as `PAT_TOKEN` in the calling repository. Give it
   `repo` and `workflow` scopes, or `public_repo` and `workflow` for public-only
   operations. It must read the source and create/write repositories under the
   target owner. Organization policies/SSO may require extra authorization.
   `GITHUB_TOKEN` cannot create repositories. A workflow `permissions:` map
   controls that token only; `workflows: write` is not a valid map entry.
3. Choose a target name that does not exist. Creation fails rather than
   overwriting an existing repository. Do not use this as a rerunnable updater.
4. This action repository is private. For direct use in another private repo
   owned by `bartuf00`, enable **Settings > Actions > General > Access** in
   `clone_git`. Private sharing does not grant access to public or unrelated
   accounts' repositories. Do not change visibility just to fix an access error.
5. For a **private upstream**, add an `UPSTREAM_TOKEN` secret to the created
   target, with read access to upstream and write access to target. Use the
   classic `repo` and `workflow` scopes when upstream updates contain workflows.
   The provisioning token is deliberately not saved or copied to the target.
   Public-upstream sync uses the target's `GITHUB_TOKEN` unless this secret is set.

See [private action sharing](https://docs.github.com/en/actions/how-tos/reuse-automations/share-across-private-repositories)
and [scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).

## Usage

Copy `examples/refork-example.yml` into the calling repository's
`.github/workflows/`, replace the source/target placeholders, and run it manually.
No checkout of the caller is needed unless you build or upload a release asset.

```yaml
name: Create standalone mirror
on:
  workflow_dispatch:
permissions: {}
jobs:
  provision:
    runs-on: ubuntu-latest
    steps:
      - uses: bartuf00/clone_git@main
        with:
          source_repo_url: example/upstream
          target_repo: bartuf00/standalone-project
          token: ${{ secrets.PAT_TOKEN }}
          sync_strategy: merge
```

`main` is the currently available ref, not an immutable release. There is no
published `v1` tag yet. Pin a reviewed full commit SHA for reproducibility.
For local use, check out this repo first and use `uses: ./` at its root, not
the removed `./refork-action` path.

## Inputs and outputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `source_repo_url` | yes | empty | GitHub HTTPS URL, `owner/repo`, or GitHub SSH URL. All are normalized to HTTPS and authenticated with the PAT, not SSH keys. |
| `target_repo` | yes | empty | **New** repository as `owner/name`. |
| `visibility` | no | `private` | `private` or `public`. Public exposes all mirrored history. |
| `sync_cron` | no | `0 4 * * *` | Five-field UTC cron. GitHub supports intervals of at least five minutes; runs may be delayed. |
| `sync_strategy` | no | `merge` | `merge`, `ff-only`, or `rebase`; see below. |
| `upstream_branch` | no | `main` | Existing upstream branch. Set this explicitly for repos using `master` or another name. |
| `target_branch` | no | `main` | Target branch and new default branch. If absent upstream, it is created from `upstream_branch`. |
| `release_tag` | no | empty | Create/use a release **in the target**, optionally without an asset. |
| `release_asset_path` | no | empty | File relative to the caller workspace or an absolute path. Names containing `#`, `*`, `?`, or backslashes are rejected because of CLI label/glob semantics. |
| `token` | yes | empty | Classic PAT used for creation, Git authentication, workflow installation, and releases. |

Outputs:
- `target_repo_url`: `https://github.com/owner/name`.
- `sync_workflow_path`: repository-relative `.github/workflows/upstream-sync.yml`,
  not a surviving runner checkout path.

## Synchronization behavior

Provisioning adds `.github/workflows/upstream-sync.yml`,
`.github/refork/sync-upstream.sh`, and `.github/refork/lfs_archive.py` in a new
commit **on the target only**. The caller workspace is not changed.
`target_branch` is made the default because scheduled workflows run only from
the default branch. The generated workflow can also be dispatched manually and
serializes sync runs to reduce push races.

## LFS release archives

Every provision and every scheduled sync runs the archive helper against the
upstream's full history (all branches and tags):

1. Historical LFS objects are enumerated with `git lfs ls-files --all --json`,
   so objects deleted from the current tree are included.
2. Each object is downloaded from the upstream LFS store only, verified against
   its SHA-256 pointer, split into chunks under GitHub's 2 GiB per-asset limit,
   and uploaded to a **draft** release `lfs-archive/<sha256>`.
3. The release is published only after the manifest and all chunks verify.
   Published archives are append-only: reruns verify and skip them, never
   clobber or delete. A failed run leaves a resumable draft, not a broken
   archive.
4. Nothing is ever pushed to the target's LFS storage (`GIT_LFS_SKIP_PUSH=1`
   is enforced for every Git operation).

If the upstream repository or its LFS store later disappears, the payloads stay
downloadable from your target's releases.

### Restoring LFS files

The helper is installed in the target at `.github/refork/lfs_archive.py`. In a
clean checkout of the target (including a detached historical commit), run:

```sh
python3 .github/refork/lfs_archive.py restore owner/target
```

It requires no upstream access: it downloads the needed objects from the
target's releases, verifies every chunk and the assembled object hash, places
them in the local Git LFS cache, and runs `git lfs checkout`. It refuses to run
in a dirty worktree and never contacts any LFS server.

When checking out an old commit in a repository whose LFS server is gone,
disable automatic smudging first, then restore:

```sh
GIT_LFS_SKIP_SMUDGE=1 git checkout <commit-or-tag>
python3 .github/refork/lfs_archive.py restore owner/target
```

Limitations: release assets are independent of Git LFS pointers — a plain
`git clone` still shows pointer files until you run `restore`. GitHub limits
each release to 1,000 assets and 2 GiB per file; objects larger than
~999 GiB are rejected. Submodules are not archived.

- **`merge` (default):** preserves local setup/customizations while incorporating
  upstream changes. Conflicts fail and abort without pushing.
- **`ff-only`:** refuses divergence without changing history. Installing the sync
  files itself introduces divergence, so this strategy normally fails after the
  first upstream update. It is an explicit strict-history option, not the default.
- **`rebase`:** replays local commits on upstream and rewrites target history.
  Push uses an explicit `--force-with-lease` against the fetched target SHA so a
  concurrent update is not overwritten. Protected branches may reject this.

The runtime checks out the requested target branch and requires a clean worktree.
`DRY_RUN=1` for `sync-upstream.sh` means **no push**, not no local changes.
Scheduled workflows in public repos can be disabled after 60 days of inactivity.
If upstream modifies workflow files, the default `GITHUB_TOKEN` may be unable to
push them; configure `UPSTREAM_TOKEN` with the appropriate workflow scope.

## Releases, trust, and partial failures

New releases use `target_branch` if the tag does not already exist. Existing tags
keep their original commits. Asset uploads skip identical content and replace
different content of the same name. Checkout/build the asset before this action;
the mirrored repository is not a build workspace for the caller.

Only mirror repositories you trust: source workflows are copied too and may run
in the target. Workflow/runtime paths above are reserved and overwritten by the
installer. Later upstream changes to those files can conflict. Review source
workflows before granting the target secrets or enabling Actions.

Provisioning is not transactional: a push, workflow-install, or release failure
after creation can leave a partially configured target. Inspect the error and
repair it manually, or deliberately remove the target before retrying. The action
never deletes a repository or overwrites an existing one automatically.

## Local checks

Install Bats, ShellCheck, and actionlint; install Python 3 with PyYAML for the
composite integration test and pytest plus Git LFS for the archive tests. No
live GitHub repository is created by the tests: they use local Git/LFS
repositories and CLI stubs at the GitHub boundary.

```sh
bats tests
python3 -m pytest tests -q
shellcheck scripts/*.sh
for script in scripts/*.sh; do sh -n "$script"; done
actionlint examples/refork-example.yml
sh scripts/install-sync-workflow.sh --dry-run /tmp/target example/upstream '17 4 * * *' merge main main
```

Each script supports `--help`. Rendering validates branch refs, cron ranges, and
single-line values, escapes YAML quotes, and rejects embedded GitHub expressions.
Dry-run provisioning/release plans never include the token value.
