#!/bin/sh
set -eu

usage() { printf 'Usage: %s [--dry-run] TAG FILE\n' "${0##*/}" >&2; exit 2; }

main() {
    dry_run=0
    if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
    [ "$#" -eq 2 ] || usage
    tag=$1
    file=$2
    [ -n "$tag" ] || usage
    [ -f "$file" ] || { printf 'File not found: %s\n' "$file" >&2; exit 1; }
    tmp_dir=$(mktemp -d)
    cleanup() { rm -rf "$tmp_dir"; }
    trap cleanup EXIT HUP INT TERM
    asset_name=${file##*/}
    local_hash=$(sha256sum "$file" | awk '{print $1}')
    if [ "$dry_run" -eq 1 ]; then
        printf '+ gh release view %s\n' "$tag"
        printf '+ gh release create %s\n' "$tag"
        printf '+ gh release download %s --pattern %s --dir %s\n' "$tag" "$asset_name" "$tmp_dir"
        printf '+ gh release upload --clobber %s %s\n' "$tag" "$file"
        return 0
    fi
    if ! gh release view "$tag" >/dev/null 2>&1; then
        gh release create "$tag"
    fi
    if gh release download "$tag" --pattern "$asset_name" --dir "$tmp_dir" >/dev/null 2>&1; then
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
