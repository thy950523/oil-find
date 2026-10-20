#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=release
APP_PATH="$PROJECT_DIR/build/Oil Find.app"
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --debug) [[ $# -eq 1 ]] || exit 2; CONFIGURATION=debug; APP_PATH="$PROJECT_DIR/build/debug/Oil Find.app" ;;
    *) printf '%s\n' 'Usage: scripts/build-app.sh [--debug]' >&2; exit 2 ;;
esac
swift build -c "$CONFIGURATION"
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/OilFind" "$APP_PATH/Contents/MacOS/OilFind"
if [[ "$CONFIGURATION" == release ]]; then
    # Release bundles omit debug symbols containing local source paths.
    strip -S "$APP_PATH/Contents/MacOS/OilFind"
fi
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
# The packaging date goes into the built bundle, not the repository, so it describes the app in hand
# and the settings pane can show it. UTC, so the value does not depend on this machine's time zone.
# It has to be written before signing: the signature covers Info.plist.
/usr/libexec/PlistBuddy -c "Add :OilFindPackagedAt string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP_PATH/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
# Copy only resource bundles declared by the active package, including optional targets.
swift package describe --type json | python3 -c '
import json, pathlib, shutil, sys
package = json.load(sys.stdin)
binary, resources = map(pathlib.Path, sys.argv[1:])
for old in resources.glob(package["name"] + "_*.bundle"):
    shutil.rmtree(old)
for target in package["targets"]:
    if target.get("resources"):
        name = package["name"] + "_" + target["c99name"] + ".bundle"
        shutil.copytree(binary / name, resources / name)
' "$BINARY_DIR" "$APP_PATH/Contents/Resources"
SELF_SIGNED="Oil Find Self-Signed"
if [[ -n "${OILFIND_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$OILFIND_SIGN_IDENTITY" --identifier com.oiloil.find --options runtime --timestamp "$APP_PATH"
elif security find-identity -v -p codesigning | grep -q "\"$SELF_SIGNED\""; then
    # Stable identity: macOS keeps Full Disk Access across updates. See scripts/create-signing-cert.sh.
    codesign --force --sign "$SELF_SIGNED" --identifier com.oiloil.find "$APP_PATH"
else
    codesign --force --sign - --identifier com.oiloil.find "$APP_PATH"
fi
printf '%s\n' "$APP_PATH"
