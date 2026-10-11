#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--dry-run] SOURCE_URL TARGET_REPO\n' "${0##*/}" >&2
    exit 2
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

main() {
    DRY_RUN=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            -*) usage ;;
            *) break ;;
        esac
    done
    [ "$#" -eq 2 ] || usage
    source_url=$1
    target_repo=$2
    : "${PAT_TOKEN:?PAT_TOKEN is required}"
    case "$target_repo" in
        */*) : ;;
        *) printf 'Invalid TARGET_REPO: %s\n' "$target_repo" >&2; exit 2 ;;
    esac
    target_owner=${target_repo%%/*}
    target_name=${target_repo#*/}
    case "$source_url" in
        https://github.com/*/*)
            source_path=${source_url#https://github.com/}
            source_path=${source_path%%\?*}
            source_path=${source_path%%#*}
            source_owner=${source_path%%/*}
            source_name=${source_path#*/}
            source_name=${source_name%.git}
            ;;
        */*)
            source_owner=${source_url%%/*}
            source_name=${source_url#*/}
            source_name=${source_name%.git}
            ;;
        *) printf 'SOURCE_URL must be a GitHub HTTPS URL or owner/repo\n' >&2; exit 2 ;;
    esac
    [ -n "$source_owner" ] && [ -n "$source_name" ] || usage
    visibility=${VISIBILITY:-private}
    case "$visibility" in public|private) : ;; *) printf 'VISIBILITY must be public or private\n' >&2; exit 2 ;; esac
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ gh repo create %s --%s\n' "$target_repo" "$visibility"
    else
        GH_TOKEN=$PAT_TOKEN gh repo create "$target_repo" "--$visibility" >/dev/null
    fi
    tmp_dir=$(mktemp -d)
    cleanup() { rm -rf "$tmp_dir"; }
    trap cleanup EXIT HUP INT TERM
    target_url=https://github.com/$target_repo.git
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ git clone --bare %s %s\n' "$source_url" "$tmp_dir/mirror.git"
    else
        git -c http.extraheader="AUTHORIZATION: bearer $PAT_TOKEN" clone --bare "$source_url" "$tmp_dir/mirror.git"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ git -C %s push --mirror %s\n' "$tmp_dir/mirror.git" "$target_url"
    else
        git -C "$tmp_dir/mirror.git" -c http.extraheader="AUTHORIZATION: bearer $PAT_TOKEN" push --mirror "$target_url"
    fi
}

if [ "${0##*/}" = "create-mirror.sh" ]; then
    main "$@"
fi
