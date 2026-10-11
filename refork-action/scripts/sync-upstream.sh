#!/bin/sh
set -eu

usage() { printf 'Usage: %s [UPSTREAM_URL [UPSTREAM_BRANCH [TARGET_BRANCH [STRATEGY]]]]\n' "${0##*/}" >&2; exit 2; }

main() {
    [ "$#" -le 4 ] || usage
    upstream_url=${1:-${UPSTREAM_URL:-}}
    upstream_branch=${2:-${UPSTREAM_BRANCH:-main}}
    target_branch=${3:-${TARGET_BRANCH:-main}}
    strategy=${4:-${STRATEGY:-ff-only}}
    [ -n "$upstream_url" ] || { printf 'UPSTREAM_URL is required\n' >&2; exit 2; }
    case "$strategy" in ff-only|merge|rebase) : ;; *) printf 'Invalid STRATEGY: %s\n' "$strategy" >&2; exit 2 ;; esac
    git fetch "$upstream_url" "$upstream_branch"
    local_sha=$(git rev-parse "$target_branch")
    upstream_sha=$(git rev-parse FETCH_HEAD)
    if [ "$local_sha" = "$upstream_sha" ]; then
        printf 'Already synchronized at %s\n' "$local_sha"
        return 0
    fi
    case "$strategy" in
        ff-only) git merge --ff-only "$upstream_sha" ;;
        merge)
            if ! git merge --no-edit "$upstream_sha"; then
                git merge --abort || { printf 'Unable to abort merge after conflict\n' >&2; return 1; }
                return 1
            fi
            ;;
        rebase)
            if ! git rebase "$upstream_sha"; then
                git rebase --abort || { printf 'Unable to abort rebase after conflict\n' >&2; return 1; }
                return 1
            fi
            ;;
    esac
    if [ "${DRY_RUN:-0}" = 1 ]; then
        printf 'DRY_RUN=1: skipping push to %s\n' "$target_branch"
    else
        git push origin "HEAD:$target_branch"
    fi
}

if [ "${0##*/}" = "sync-upstream.sh" ]; then
    main "$@"
fi
