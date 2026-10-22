#!/bin/zsh
# Builds SamsungMac.app (arm64 release). Use --install to copy to /Applications and launch.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/SamsungMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SamsungMac "$APP/Contents/MacOS/SamsungMac"
# Newer SwiftPM links with the deployment target recorded as the SDK
# version, and macOS then draws the menu bar panel in its old compatibility
# style. Record the real SDK so the panel gets the current system look.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/SamsungMac" "$APP/Contents/MacOS/SamsungMac"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x SamsungMac 2>/dev/null || true
    sleep 0.4
    rm -rf /Applications/SamsungMac.app
    cp -R "$APP" /Applications/SamsungMac.app
    open /Applications/SamsungMac.app
    echo "Installed to /Applications/SamsungMac.app and launched"
fi
