#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo "This app requires macOS 14+ and Xcode command-line tools." >&2
    exit 1
fi
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
swift test
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Disposable Browser.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DisposableBrowser" "$APP/Contents/MacOS/DisposableBrowser"
# SwiftPM resource bundles (including KeyboardShortcuts localizations).
for bundle in "$BIN"/*.bundle; do
    [[ ! -d "$bundle" ]] || cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
echo "Launch with: open \"$APP\""
