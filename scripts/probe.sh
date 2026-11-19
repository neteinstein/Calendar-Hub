#!/usr/bin/env bash
set -x
scripts/build-app.sh
find "build/Calendar Hub.app" | head -40
find "build/Calendar Hub.app/Contents/Resources/Metadata.appintents" -type f -exec sh -c 'echo "== $1"; head -c 2500 "$1"; echo' _ {} \;
codesign --verify --deep --strict --verbose=2 "build/Calendar Hub.app"
codesign -d --entitlements - "build/Calendar Hub.app/Contents/PlugIns/CalendarHubWidget.appex"
plutil -p "build/Calendar Hub.app/Contents/PlugIns/CalendarHubWidget.appex/Contents/Info.plist"
pluginkit -a "build/Calendar Hub.app/Contents/PlugIns/CalendarHubWidget.appex"; pluginkit -m -v -p com.apple.widgetkit-extension | grep -i calendarhub
