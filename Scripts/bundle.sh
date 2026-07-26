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

# Release ships a universal binary (Apple Silicon + Intel); Debug builds only
# for this machine, because compiling twice doubles the edit-run loop. Set
# UNIVERSAL=1 to force both architectures in Debug too.
if [ "$CONFIG" = "Release" ] || [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_ARGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
else
    ARCH_ARGS=(ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES)
fi

# DISABLE_SWIFTLINT: the SwiftLint build plugin used by CodeEdit's packages
# fails under Xcode 26 ("The folder Output doesn't exist"); the plugin itself
# offers this opt-out.
DISABLE_SWIFTLINT=1 xcodebuild \
    -scheme Workspace \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -configuration "$CONFIG" \
    -skipPackagePluginValidation \
    "${ARCH_ARGS[@]}" \
    build >&2

APP="$PRODUCTS/Workspace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Workspace" "$APP/Contents/MacOS/Workspace"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Package resource bundles (tree-sitter queries, symbols) sit next to the
# executable; the app looks for them in Resources.
for bundle in "$PRODUCTS"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Ghostty runtime resources: terminfo + shell integration. GhosttyRuntime
# points GHOSTTY_RESOURCES_DIR at Resources/ghostty before ghostty_init.
# These are checked in (Resources/ghostty-share) so a fresh clone can bundle
# the app without fetching anything beyond the SwiftPM dependencies.
cp -R Resources/ghostty-share/ghostty "$APP/Contents/Resources/ghostty"
cp -R Resources/ghostty-share/terminfo "$APP/Contents/Resources/terminfo"

# Ad-hoc signature: enough for local runs and keeps macOS from complaining.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
