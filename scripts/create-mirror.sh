#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--dry-run] SOURCE_URL TARGET_REPO\n' "${0##*/}" >&2
}

validate_repo() {
    case "$1" in
        */*/*|/*|*/|-*|*/*[!a-zA-Z0-9_.-]*|*[!a-zA-Z0-9_./-]*|*/.|*/..|*/-*) return 1 ;;
        */*) return 0 ;;
        *) return 1 ;;
    esac
}

main() {
    if [ "${1:-}" = "--help" ]; then usage; return; fi
    DRY_RUN=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            -*) usage; exit 2 ;;
            *) break ;;
        esac
    done
    [ "$#" -eq 2 ] || { usage; exit 2; }
    source_url=$1
    target_repo=$2
    : "${PAT_TOKEN:?PAT_TOKEN is required}"
    validate_repo "$target_repo" || { printf 'Invalid TARGET_REPO: %s\n' "$target_repo" >&2; exit 2; }
    case "$source_url" in
        https://github.com/*/*)
            source_path=${source_url#https://github.com/}
            ;;
        git@github.com:*) source_path=${source_url#git@github.com:} ;;
        ssh://git@github.com/*) source_path=${source_url#ssh://git@github.com/} ;;
        */*) source_path=$source_url ;;
        *) printf 'SOURCE_URL must be a GitHub HTTPS URL or owner/repo (GitHub SSH URLs also accepted)\n' >&2; exit 2 ;;
    esac
    source_path=${source_path%.git}
    validate_repo "$source_path" || { printf 'Invalid SOURCE_URL: %s\n' "$source_url" >&2; exit 2; }
    source_url=https://github.com/$source_path.git
    visibility=${VISIBILITY:-private}
    case "$visibility" in public|private) : ;; *) printf 'VISIBILITY must be public or private\n' >&2; exit 2 ;; esac
    export GH_TOKEN="$PAT_TOKEN" GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0=''
    export GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1='!gh auth git-credential'
    tmp_dir=$(mktemp -d)
    cleanup() { rm -rf "$tmp_dir"; }
    trap cleanup EXIT HUP INT TERM
    target_url=https://github.com/$target_repo.git
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ git clone --bare %s %s\n' "$source_url" "$tmp_dir/mirror.git"
    else
        git clone --bare "$source_url" "$tmp_dir/mirror.git"
        upstream_branch=${UPSTREAM_BRANCH:-$(git -C "$tmp_dir/mirror.git" symbolic-ref --short HEAD)}
        target_branch=${TARGET_BRANCH:-$upstream_branch}
        git check-ref-format --branch "$upstream_branch" >/dev/null
        git check-ref-format --branch "$target_branch" >/dev/null
        upstream_sha=$(git -C "$tmp_dir/mirror.git" rev-parse --verify "refs/heads/$upstream_branch^{commit}")
        if ! git -C "$tmp_dir/mirror.git" show-ref --verify --quiet "refs/heads/$target_branch"; then
            git -C "$tmp_dir/mirror.git" update-ref "refs/heads/$target_branch" "$upstream_sha"
        fi
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ gh repo create %s --%s\n' "$target_repo" "$visibility"
    else
        gh repo create "$target_repo" "--$visibility" >/dev/null
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ git -C %s push --mirror %s\n' "$tmp_dir/mirror.git" "$target_url"
    else
        git -C "$tmp_dir/mirror.git" push --mirror "$target_url"
        gh repo edit "$target_repo" --default-branch "$target_branch"
    fi
}

if [ "${0##*/}" = "create-mirror.sh" ]; then
    main "$@"
fi
