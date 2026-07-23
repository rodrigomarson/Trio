#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIRECTORY=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
APP_DIRECTORY="$PACKAGE_DIRECTORY/.build/MicroTechDiscoveryProbe.app"

cd "$PACKAGE_DIRECTORY"
swift build -c release --product MicroTechDiscoveryProbe
BIN_DIRECTORY=$(swift build -c release --show-bin-path)

mkdir -p "$APP_DIRECTORY/Contents/MacOS"
mkdir -p "$APP_DIRECTORY/Contents/Resources"
cp "$BIN_DIRECTORY/MicroTechDiscoveryProbe" \
    "$APP_DIRECTORY/Contents/MacOS/MicroTechDiscoveryProbe"
cp "$PACKAGE_DIRECTORY/Tools/MicroTechDiscoveryProbe/Info.plist" \
    "$APP_DIRECTORY/Contents/Info.plist"

/usr/bin/plutil -lint "$APP_DIRECTORY/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIRECTORY"

echo "Prepared: $APP_DIRECTORY"
echo "Do not run the probe until the physical sensor is available."
