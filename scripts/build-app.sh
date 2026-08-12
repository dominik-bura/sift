#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${1:-release}"
product_dir="$repo_dir/build"
app_dir="$product_dir/Sift.app"
version="${SIFT_VERSION:-0.1.0}"
build_number="${SIFT_BUILD_NUMBER:-1}"
update_repository="${SIFT_UPDATE_REPOSITORY:-}"
codesign_identity="${SIFT_CODESIGN_IDENTITY:--}"

cd "$repo_dir"
mkdir -p "$repo_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/module-cache"
build_arguments=(-c "$configuration" --disable-sandbox)
if [[ "${SIFT_UNIVERSAL:-0}" == "1" ]]; then
    build_arguments+=(--arch arm64 --arch x86_64)
fi
swift build "${build_arguments[@]}"

binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
binary_path="$binary_dir/Sift"
updater_path="$binary_dir/SiftUpdater"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp "$binary_path" "$app_dir/Contents/MacOS/Sift"
cp "$updater_path" "$app_dir/Contents/Helpers/SiftUpdater"
cp "$repo_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/App/Assets/Sift.icns" "$app_dir/Contents/Resources/Sift.icns"
cp "$repo_dir/App/Assets/SiftMenuBarIconTemplate.png" "$app_dir/Contents/Resources/SiftMenuBarIconTemplate.png"
cp "$repo_dir/App/Assets/SiftMenuBarIconTemplate@2x.png" "$app_dir/Contents/Resources/SiftMenuBarIconTemplate@2x.png"
cp "$repo_dir/App/Assets/SiftMenuBarIconTemplate@3x.png" "$app_dir/Contents/Resources/SiftMenuBarIconTemplate@3x.png"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SiftUpdateRepository $update_repository" "$app_dir/Contents/Info.plist"
codesign --force --options runtime --sign "$codesign_identity" "$app_dir/Contents/Helpers/SiftUpdater"
codesign --force --deep --options runtime --sign "$codesign_identity" "$app_dir"

echo "$app_dir"
