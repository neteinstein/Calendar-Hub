#!/usr/bin/env bash
set -euxo pipefail
brew install webp >/dev/null
# Midday somewhere, so the sample meetings sit in the working day.
sed 's/open -n -g -W --env CALENDAR_HUB_SNAPSHOTS="$png"/open -n -g -W --env TZ=America\/Chicago --env CALENDAR_HUB_SNAPSHOTS="$png"/' scripts/screenshots.sh > /tmp/shots.sh
chmod +x /tmp/shots.sh
cp /tmp/shots.sh scripts/shots-ci.sh
scripts/shots-ci.sh
git status --short docs/screenshots | head -50
