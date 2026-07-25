#!/bin/bash
# Builds, bundles and launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(Scripts/bundle.sh "${1:-Debug}")"
# `open` only activates an already-running copy, which would leave the previous
# build on screen. Quit it first so the fresh binary is what launches.
pkill -f "Workspace.app/Contents/MacOS/Workspace" 2>/dev/null || true
echo "Launching $APP"
open "$APP"
