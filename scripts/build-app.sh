#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${1:-release}"
product_dir="$repo_dir/build"
app_dir="$product_dir/DevSweep.app"

cd "$repo_dir"
mkdir -p "$repo_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/module-cache"
swift build -c "$configuration" --disable-sandbox

binary_path="$(swift build -c "$configuration" --disable-sandbox --show-bin-path)/DevSweep"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/DevSweep"
cp "$repo_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
