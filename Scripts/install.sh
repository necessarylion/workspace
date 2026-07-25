#!/bin/bash
# Builds a Release bundle and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
DEST="/Applications/Workspace.app"

APP="$(Scripts/bundle.sh "$CONFIG")"

# Replace rather than merge, so files dropped from a newer build don't linger.
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# The Dock and Finder cache icons per bundle path; re-registering makes a
# changed icon show up without a logout.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" 2>/dev/null || true
touch "$DEST"

echo "$DEST"
