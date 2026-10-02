#!/bin/sh
# Builds SimBLE.app and packages it as .build/SimBLE-<version>.dmg with an Applications shortcut.
# The app is signed for development only (see build.sh), so on other Macs Gatekeeper asks before
# the first launch: right-click the app and choose Open.
set -eu
cd "$(dirname "$0")"
./build.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
staging=".build/dmg"
dmg=".build/SimBLE-$version.dmg"
rm -rf "$staging" "$dmg"
mkdir -p "$staging"
cp -R .build/SimBLE.app "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "SimBLE $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$staging"
echo "Built $(pwd)/$dmg"
