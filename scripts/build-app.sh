#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${1:-release}"
product_dir="$repo_dir/build"
build_channel="${SIFT_BUILD_CHANNEL:-development}"
codesign_identity="${SIFT_CODESIGN_IDENTITY:--}"
build_reference="$(git -C "$repo_dir" rev-parse --short=8 HEAD 2>/dev/null || printf 'unknown')"
if [[ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]; then
    build_reference="${build_reference}-dirty"
fi

case "$build_channel" in
    development)
        app_name="Sift Dev"
        bundle_identifier="com.dominikbura.sift.dev"
        app_dir="$product_dir/Sift Dev.app"
        version="0.0.0"
        build_number="1"
        update_repository=""
        ;;
    production)
        app_name="Sift"
        bundle_identifier="com.dominikbura.sift"
        app_dir="$product_dir/Sift.app"
        version="${SIFT_VERSION:-}"
        build_number="${SIFT_BUILD_NUMBER:-}"
        update_repository="${SIFT_UPDATE_REPOSITORY:-}"
        if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
            echo "Production builds require SIFT_VERSION in x.y.z form" >&2
            exit 64
        fi
        if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
            echo "Production builds require a positive SIFT_BUILD_NUMBER" >&2
            exit 64
        fi
        if [[ ! "$update_repository" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]]; then
            echo "Production builds require SIFT_UPDATE_REPOSITORY as owner/repository" >&2
            exit 64
        fi
        ;;
    *)
        echo "SIFT_BUILD_CHANNEL must be development or production" >&2
        exit 64
        ;;
esac

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
cp "$repo_dir/App/Assets/SiftAppIcon-1024.png" "$app_dir/Contents/Resources/SiftAppIcon-1024.png"
cp "$repo_dir/App/Assets/SiftFunnel.svg" "$app_dir/Contents/Resources/SiftFunnel.svg"
cp "$repo_dir/App/Assets/SiftMenuBarIconTemplate.png" "$app_dir/Contents/Resources/SiftMenuBarIconTemplate.png"
cp "$repo_dir/App/Assets/SiftMenuBarIconTemplate@2x.png" "$app_dir/Contents/Resources/SiftMenuBarIconTemplate@2x.png"
cp "$repo_dir/App/Assets/SiftMenuBarIconTemplate@3x.png" "$app_dir/Contents/Resources/SiftMenuBarIconTemplate@3x.png"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SiftUpdateRepository $update_repository" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SiftBuildChannel string $build_channel" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SiftBuildReference string $build_reference" "$app_dir/Contents/Info.plist"
codesign --force --options runtime --sign "$codesign_identity" "$app_dir/Contents/Helpers/SiftUpdater"
codesign --force --deep --options runtime --sign "$codesign_identity" "$app_dir"

echo "$app_dir"
