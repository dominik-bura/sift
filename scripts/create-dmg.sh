#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 /path/to/Sift.app /path/to/Sift-version.dmg" >&2
    exit 64
fi

app_path="${1:A}"
output_path="${2:A}"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
    echo "Expected an application bundle, got: $app_path" >&2
    exit 66
fi

if [[ "$output_path" != *.dmg ]]; then
    echo "Output path must end in .dmg: $output_path" >&2
    exit 64
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/sift-dmg.XXXXXX")"
cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "${output_path:h}"
/usr/bin/ditto "$app_path" "$staging_dir/Sift.app"
/bin/ln -s /Applications "$staging_dir/Applications"

/usr/bin/hdiutil create \
    -volname "Sift" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$output_path"

echo "$output_path"
