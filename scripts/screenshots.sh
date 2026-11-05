#!/bin/bash
# Renders the README's screenshots into docs/screenshots: the menu (Month, List, Tasks, Stats), the
# meeting alert, a task's notes window, the menu bar item and each Settings pane, in light and
# dark, as WebP.
#
# The app draws them itself with sample calendars (Work, Calendar A, Client X), so nothing from
# your own calendars ends up in them, and it can run next to your running copy. Today's sample
# meetings sit around the current time, so run it during the day. Needs cwebp
# (`brew install webp`).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp" >&2; exit 1; }
scripts/build-app.sh >/dev/null
png="$(mktemp -d)"
out="$PWD/docs/screenshots"
mkdir -p "$out"

# A new instance even while another copy runs, opened through LaunchServices so macOS lists
# it as its own app (not under the shell that ran it); -W waits for it to finish and quit.
open -n -W --env CALENDAR_SYNC_SNAPSHOTS="$png" "build/Calendar Sync.app"

for file in "$png"/*.png; do
    cwebp -quiet -q 86 "$file" -o "$out/$(basename "${file%.png}").webp"
done
rm -rf "$png"
ls "$out"
