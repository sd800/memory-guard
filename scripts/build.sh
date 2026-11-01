#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then echo 'Usage: scripts/build.sh [release|debug]' >&2; exit 2; fi
xcrun swift build --disable-sandbox -c "$configuration" -j 2
bin_dir="$(xcrun swift build --disable-sandbox -c "$configuration" --show-bin-path)"
staging_dir="$(mktemp -d /private/tmp/MemoryGuard-build.XXXXXX)"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Memory Guard.app"
output_app="$PWD/build/Products.noindex/Memory Guard.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources" "$app_dir/Contents/Library/LaunchAgents"
cp "$bin_dir/MemoryGuard" "$app_dir/Contents/MacOS/MemoryGuard"
cp "$bin_dir/GuardAgent" "$app_dir/Contents/Helpers/GuardAgent"
cp "$bin_dir/GuardRecovery" "$app_dir/Contents/Helpers/GuardRecovery"
cp Config/Info.plist "$app_dir/Contents/Info.plist"
cp Config/local.memoryguard.*.plist "$app_dir/Contents/Library/LaunchAgents/"
if [[ ! -f Resources/MemoryGuardIcon.icns || Resources/AppIcon.png -nt Resources/MemoryGuardIcon.icns || scripts/icon.swift -nt Resources/MemoryGuardIcon.icns ]]; then
    xcrun swift scripts/icon.swift
    iconutil -c icns build/AppIcon.iconset -o Resources/MemoryGuardIcon.icns
fi
cp Resources/MemoryGuardIcon.icns "$app_dir/Contents/Resources/"
cp Resources/AppIcon.png "$app_dir/Contents/Resources/MemoryGuardArtwork.png"
xcrun actool Resources/Assets.xcassets --compile "$app_dir/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 --app-icon MemoryGuardIcon --output-partial-info-plist "$staging_dir/icon-info.plist" --output-format human-readable-text
xattr -cr "$app_dir"
identity="${SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --options runtime --identifier local.memoryguard.agent "$app_dir/Contents/Helpers/GuardAgent"
codesign --force --sign "$identity" --options runtime --identifier local.memoryguard.recovery "$app_dir/Contents/Helpers/GuardRecovery"
codesign --force --sign "$identity" --options runtime "$app_dir"
codesign --verify --deep --strict "$app_dir"
mkdir -p "$PWD/build/Products.noindex"
# This is the generated bundle only; a fresh copy avoids stale sealed resources after icon renames.
# Remove the old indexed output as well when upgrading an existing checkout.
rm -rf -- "$output_app" "$PWD/build/Memory Guard.app"
ditto --norsrc --noextattr "$app_dir" "$output_app"
xattr -dr com.apple.FinderInfo "$output_app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$output_app" 2>/dev/null || true
# File Provider can asynchronously reattach FinderInfo on a synced Documents folder.
# Verify the payload here; strict checks also run on the original and unpacked release.
codesign --verify --deep "$output_app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Config/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Config/Info.plist)"
ditto -c -k --norsrc --keepParent "$app_dir" "$PWD/build/MemoryGuard-$version-$build_number.zip"
ditto -x -k "$PWD/build/MemoryGuard-$version-$build_number.zip" "$staging_dir/zip-check"
codesign --verify --deep --strict "$staging_dir/zip-check/Memory Guard.app"
echo "$output_app"
