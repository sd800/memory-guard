#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
xcrun swift build --disable-sandbox -j 2 --product GuardProbe
export GUARD_PROBE_PATH="$(xcrun swift build --disable-sandbox --show-bin-path)/GuardProbe"
xcrun swift test --disable-sandbox -j 2
