#!/bin/bash
# Builds Workspace and wraps the executable in a real .app bundle, so it gets a
# Dock icon, a menu bar and normal window activation.
#
# xcodebuild is used rather than `swift build` because a dependency ships an
# asset catalog, which only Xcode's build system can compile.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
DERIVED=".build/xcode"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

# DISABLE_SWIFTLINT: the SwiftLint build plugin used by CodeEdit's packages
# fails under Xcode 26 ("The folder Output doesn't exist"); the plugin itself
# offers this opt-out.
DISABLE_SWIFTLINT=1 xcodebuild \
    -scheme Workspace \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    -configuration "$CONFIG" \
    -skipPackagePluginValidation \
    build >&2

APP="$PRODUCTS/Workspace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Workspace" "$APP/Contents/MacOS/Workspace"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Package resource bundles (tree-sitter queries, symbols) sit next to the
# executable; the app looks for them in Resources.
for bundle in "$PRODUCTS"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Ghostty runtime resources: terminfo + shell integration. GhosttyRuntime
# points GHOSTTY_RESOURCES_DIR at Resources/ghostty before ghostty_init.
cp -R .deps/ghostty-share/ghostty "$APP/Contents/Resources/ghostty"
cp -R .deps/ghostty-share/terminfo "$APP/Contents/Resources/terminfo"

# Ad-hoc signature: enough for local runs and keeps macOS from complaining.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
