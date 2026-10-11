#!/bin/sh
set -eu

usage() { printf 'Usage: %s [UPSTREAM_URL [UPSTREAM_BRANCH [TARGET_BRANCH [STRATEGY]]]]\nDRY_RUN=1 applies changes locally but skips the push.\n' "${0##*/}" >&2; }

main() {
    if [ "${1:-}" = "--help" ]; then usage; return; fi
    [ "$#" -le 4 ] || { usage; exit 2; }
    upstream_url=${1:-${UPSTREAM_URL:-}}
    upstream_branch=${2:-${UPSTREAM_BRANCH:-main}}
    target_branch=${3:-${TARGET_BRANCH:-main}}
    strategy=${4:-${STRATEGY:-merge}}
    [ -n "$upstream_url" ] || { printf 'UPSTREAM_URL is required\n' >&2; exit 2; }
    case "$strategy" in ff-only|merge|rebase) : ;; *) printf 'Invalid STRATEGY: %s\n' "$strategy" >&2; exit 2 ;; esac
    git check-ref-format --branch "$upstream_branch" >/dev/null
    git check-ref-format --branch "$target_branch" >/dev/null
    [ -z "$(git status --porcelain)" ] || { printf 'A clean worktree is required.\n' >&2; exit 1; }
    git fetch origin "refs/heads/$target_branch:refs/remotes/origin/$target_branch"
    remote_sha=$(git rev-parse "refs/remotes/origin/$target_branch")
    if git show-ref --verify --quiet "refs/heads/$target_branch"; then
        git checkout "$target_branch"
        git merge --ff-only "$remote_sha"
    else
        git checkout -b "$target_branch" "$remote_sha"
    fi
    git fetch "$upstream_url" "refs/heads/$upstream_branch"
    local_sha=$(git rev-parse HEAD)
    upstream_sha=$(git rev-parse FETCH_HEAD)
    if [ "$local_sha" = "$upstream_sha" ]; then
        printf 'Already synchronized at %s\n' "$local_sha"
    else
        case "$strategy" in
            ff-only) git merge --ff-only "$upstream_sha" ;;
            merge)
                if ! git merge --no-edit "$upstream_sha"; then
                    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then git merge --abort; fi
                    return 1
                fi
                ;;
            rebase)
                if ! git rebase "$upstream_sha"; then
                    if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then git rebase --abort; fi
                    return 1
                fi
                ;;
        esac
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then
        printf 'DRY_RUN=1: skipping push to %s\n' "$target_branch"
    else
        if [ "$strategy" = rebase ]; then
            git push --force-with-lease="refs/heads/$target_branch:$remote_sha" origin "HEAD:refs/heads/$target_branch"
        else
            git push origin "HEAD:refs/heads/$target_branch"
        fi
    fi
}

if [ "${0##*/}" = "sync-upstream.sh" ]; then
    main "$@"
fi
