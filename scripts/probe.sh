#!/usr/bin/env bash
set -x
scripts/build-app.sh
find "build/Calendar Hub.app" | head -40
find "build/Calendar Hub.app/Contents/Resources/Metadata.appintents" -type f -exec sh -c 'echo "== $1"; head -c 2500 "$1"; echo' _ {} \;
