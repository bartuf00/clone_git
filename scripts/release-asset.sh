#!/bin/sh
set -eu

usage() { printf 'Usage: %s [--dry-run] TAG [FILE]\nGH_REPO selects the repository; TARGET_BRANCH selects the release target.\n' "${0##*/}" >&2; }

main() {
    dry_run=0
    if [ "${1:-}" = "--help" ]; then usage; return; fi
    if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
    tag=$1
    file=${2:-}
    git check-ref-format "refs/tags/$tag" >/dev/null
    case "$tag" in ''|-*) usage; exit 2 ;; esac
    [ -z "$file" ] || [ -f "$file" ] || { printf 'File not found: %s\n' "$file" >&2; exit 1; }
    case "$file" in *'#'*|*'?'*|*'*'*|*\\*) printf 'Unsupported asset filename: %s\n' "$file" >&2; exit 2 ;; esac
    case "$file" in ''|/*|./*) : ;; *) file=./$file ;; esac
    tmp_dir=$(mktemp -d)
    cleanup() { rm -rf "$tmp_dir"; }
    trap cleanup EXIT HUP INT TERM
    asset_name=${file##*/}
    asset_pattern=$(printf '%s' "$asset_name" | sed 's/\[/[[]/g')
    if [ "$dry_run" -eq 1 ]; then
        printf '+ gh release view %s\n' "$tag"
        printf '+ gh release create %s --target %s --notes "" (if absent)\n' "$tag" "${TARGET_BRANCH:-main}"
        if [ -n "$file" ]; then
            printf '+ gh release download %s --pattern "%s" --dir "%s"\n' "$tag" "$asset_pattern" "$tmp_dir"
            printf '+ gh release upload --clobber %s "%s"\n' "$tag" "$file"
        fi
        return 0
    fi
    if ! gh release view "$tag" >/dev/null 2>&1; then
        gh release create "$tag" --target "${TARGET_BRANCH:-main}" --notes ''
    fi
    [ -n "$file" ] || return 0
    local_hash=$(sha256sum "$file" | awk '{print $1}')
    if gh release download "$tag" --pattern "$asset_pattern" --dir "$tmp_dir" >/dev/null 2>&1; then
        downloaded="$tmp_dir/$asset_name"
        if [ -f "$downloaded" ]; then
            remote_hash=$(sha256sum "$downloaded" | awk '{print $1}')
            if [ "$local_hash" = "$remote_hash" ]; then
                printf 'SKIP %s (identical)\n' "$asset_name"
                return 0
            fi
        fi
    fi
    gh release upload --clobber "$tag" "$file"
}

if [ "${0##*/}" = "release-asset.sh" ]; then
    main "$@"
fi
