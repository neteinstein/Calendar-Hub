#!/usr/bin/env bash
# Builds "Calendar Hub.app" into ./build.
#
#   scripts/build-app.sh                       # ad-hoc signed, for your own Mac
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#                                              # signed for sharing (then notarize, see README)
#
# Any arguments are passed on to `swift build`. The Homebrew formula passes --disable-sandbox,
# since SwiftPM can't sandbox its manifest build inside Homebrew's own build sandbox.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Calendar Hub.app"
IDENTITY="${SIGN_IDENTITY:--}"

# UNIVERSAL=1 builds for Apple silicon and Intel (needs full Xcode, not just the command line tools).
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

# Shortcuts finds the app's actions (App Intents) through metadata that Xcode's
# appintentsmetadataprocessor makes from the compiler's constant values. Without full Xcode
# (just the command line tools) it's skipped: the app works the same, its actions just aren't
# in Shortcuts. Its calendarhub:// links work either way.
INTENTS_FLAGS=()
PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
if [[ -n "$PROCESSOR" ]]; then
  PROTOCOLS="$(mktemp -t calendarhub-protocols)"
  echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]' > "$PROTOCOLS"
  INTENTS_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
                 -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS")
fi

swift build -c release --product CalendarHub ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${INTENTS_FLAGS[@]+"${INTENTS_FLAGS[@]}"} "$@"
BIN="$(swift build -c release --product CalendarHub ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${INTENTS_FLAGS[@]+"${INTENTS_FLAGS[@]}"} "$@" --show-bin-path)/CalendarHub"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CalendarHub"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$PROCESSOR" ]]; then
  CONST_VALUES="$(find .build -name 'CalendarHub.swiftconstvalues' -newer Package.swift -print 2>/dev/null | head -n 1)"
  if [[ -n "$CONST_VALUES" ]]; then
    WORK="$(mktemp -d -t calendarhub-intents)"
    find "$PWD/Sources/CalendarHub" -name '*.swift' > "$WORK/sources.txt"
    echo "$PWD/$CONST_VALUES" > "$WORK/constvalues.txt"
    XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')"
    "$PROCESSOR" \
      --toolchain-dir "$(dirname "$(dirname "$(dirname "$PROCESSOR")")")" \
      --module-name CalendarHub \
      --sdk-root "$(xcrun --show-sdk-path)" \
      --xcode-version "${XCODE_BUILD:-16F6}" \
      --platform-family macOS \
      --deployment-target 14.0 \
      --target-triple "$(uname -m)-apple-macos14.0" \
      --source-file-list "$WORK/sources.txt" \
      --swift-const-vals-list "$WORK/constvalues.txt" \
      --output "$APP/Contents/Resources" \
      --force --no-app-shortcuts-localization \
      || echo "warning: couldn't make the Shortcuts metadata; the app's actions won't be in Shortcuts" >&2
    rm -rf "$WORK"
  else
    echo "warning: no constant values for the Shortcuts metadata; the app's actions won't be in Shortcuts" >&2
  fi
fi

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp \
    --entitlements Support/CalendarHub.entitlements \
    --sign "$IDENTITY" "$APP"
fi

echo "Built $APP"
