#!/bin/zsh
set -euo pipefail

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
    echo "Usage: $0 /path/to/Sift.app /path/to/DevSweep.app [codesign-identity]" >&2
    exit 64
fi

source_app="${1:A}"
legacy_app="${2:A}"
codesign_identity="${3:--}"

if [[ ! -d "$source_app" || "$source_app:t" != "Sift.app" ]]; then
    echo "Expected Sift.app, got: $source_app" >&2
    exit 66
fi

if [[ "$legacy_app:t" != "DevSweep.app" || -e "$legacy_app" ]]; then
    echo "Legacy output must be a new DevSweep.app path: $legacy_app" >&2
    exit 64
fi

source_plist="$source_app/Contents/Info.plist"
legacy_plist="$legacy_app/Contents/Info.plist"
update_repository="$(/usr/libexec/PlistBuddy -c 'Print :SiftUpdateRepository' "$source_plist")"

case "$update_repository" in
    ""|/*|*/|*/*/*|*[!A-Za-z0-9_.\/-]*)
        echo "Sift.app has an invalid update repository" >&2
        exit 65
        ;;
esac

/usr/bin/ditto "$source_app" "$legacy_app"
# DevSweep 0.1.x validates this historical identifier before it will install an update.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.dominikhait.devsweep' "$legacy_plist"
/usr/libexec/PlistBuddy -c "Add :DevSweepUpdateRepository string $update_repository" "$legacy_plist"
/usr/bin/ditto \
    "$legacy_app/Contents/Helpers/SiftUpdater" \
    "$legacy_app/Contents/Helpers/DevSweepUpdater"

/usr/bin/codesign --force --options runtime --sign "$codesign_identity" \
    "$legacy_app/Contents/Helpers/DevSweepUpdater"
/usr/bin/codesign --force --deep --options runtime --sign "$codesign_identity" "$legacy_app"

echo "$legacy_app"
