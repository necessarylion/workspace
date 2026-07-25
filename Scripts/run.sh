#!/bin/bash
# Builds, bundles and launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(Scripts/bundle.sh "${1:-Debug}")"
echo "Launching $APP"
open "$APP"
