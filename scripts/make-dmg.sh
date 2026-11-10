#!/usr/bin/env bash
# Packs build/Calendar Hub.app into build/Calendar-Hub.dmg: the app next to a link to
# /Applications, to drag it onto. Run scripts/build-app.sh first (UNIVERSAL=1 for a download
# that runs on Intel Macs too). The release workflow attaches the result to each release.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Calendar Hub.app"
DMG="build/Calendar-Hub.dmg"
[[ -d "$APP" ]] || { echo "$APP not found: run scripts/build-app.sh first" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Calendar Hub" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
echo "Built $DMG"
