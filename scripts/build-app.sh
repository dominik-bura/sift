#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${1:-release}"
product_dir="$repo_dir/build"
app_dir="$product_dir/DevSweep.app"
version="${DEVSWEEP_VERSION:-0.1.0}"
build_number="${DEVSWEEP_BUILD_NUMBER:-1}"
update_repository="${DEVSWEEP_UPDATE_REPOSITORY:-}"
codesign_identity="${DEVSWEEP_CODESIGN_IDENTITY:--}"

if [[ -z "$update_repository" ]]; then
    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
    update_repository="$(printf '%s' "$origin_url" | /usr/bin/sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')"
    if [[ "$origin_url" != https://github.com/* && "$origin_url" != git@github.com:* ]]; then
        update_repository=""
    fi
fi

cd "$repo_dir"
mkdir -p "$repo_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/module-cache"
build_arguments=(-c "$configuration" --disable-sandbox)
if [[ "${DEVSWEEP_UNIVERSAL:-0}" == "1" ]]; then
    build_arguments+=(--arch arm64 --arch x86_64)
fi
swift build "${build_arguments[@]}"

binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
binary_path="$binary_dir/DevSweep"
updater_path="$binary_dir/DevSweepUpdater"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp "$binary_path" "$app_dir/Contents/MacOS/DevSweep"
cp "$updater_path" "$app_dir/Contents/Helpers/DevSweepUpdater"
cp "$repo_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :DevSweepUpdateRepository $update_repository" "$app_dir/Contents/Info.plist"
codesign --force --options runtime --sign "$codesign_identity" "$app_dir/Contents/Helpers/DevSweepUpdater"
codesign --force --deep --options runtime --sign "$codesign_identity" "$app_dir"

echo "$app_dir"
