#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo "This app requires macOS 14+ and Xcode command-line tools." >&2
    exit 1
fi
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
swift test
# Universal binary: macOS 14 still runs on Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
APP="$ROOT/dist/Disposable Browser.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DisposableBrowser" "$APP/Contents/MacOS/DisposableBrowser"
# SwiftPM records the deployment target as the linked SDK. Record the real SDK so
# macOS 26+ renders Liquid Glass instead of the compatibility appearance.
xcrun vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/DisposableBrowser" "$APP/Contents/MacOS/DisposableBrowser"
# SwiftPM resource bundles (including KeyboardShortcuts localizations).
for bundle in "$BIN"/*.bundle; do
    [[ ! -d "$bundle" ]] || cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Ad hoc signatures change with every build, so macOS drops Accessibility access after
# each rebuild. A certificate identity keeps the signing requirement stable. Set
# CODESIGN_IDENTITY, or put the identity in the git-ignored .codesign-identity file.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$ROOT/.codesign-identity" ]]; then
    IDENTITY="$(tr -d '[:space:]' < "$ROOT/.codesign-identity")"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "warning: signing ad hoc; Accessibility access resets after each rebuild." >&2
    echo "  List identities: security find-identity -v -p codesigning" >&2
    codesign --force --deep --sign - "$APP"
fi
echo "Built: $APP"
echo "Launch with: open \"$APP\""
