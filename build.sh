#!/bin/sh
# Builds .build/SimBLE.app: the Mac app plus the simulator loader, shim and LLDB hook it installs.
# Signs with the first Apple Development identity (override with SIGN_IDENTITY) so the Bluetooth
# permission survives rebuilds; falls back to ad-hoc signing, which asks again after every build.
set -eu
cd "$(dirname "$0")"
app=".build/SimBLE.app"
arch="$(uname -m)"
rm -rf "$app" .build/DecoderKit
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp App/Info.plist "$app/Contents/Info.plist"
cp Icon/AppIcon.icns "$app/Contents/Resources/"

# Decoder interface shared by the app and every plugin; library evolution keeps older plugins loading.
kit=".build/DecoderKit"
mkdir -p "$kit" "$app/Contents/Frameworks" "$app/Contents/PlugIns"
xcrun --sdk macosx swiftc -O -swift-version 6 -parse-as-library -enable-library-evolution \
    -target "$arch-apple-macos14.4" -module-name SimBLEDecoderKit \
    -emit-module -emit-module-path "$kit/SimBLEDecoderKit.swiftmodule" \
    -emit-library -Xlinker -install_name -Xlinker @rpath/libSimBLEDecoderKit.dylib -o "$kit/libSimBLEDecoderKit.dylib" DecoderKit/DecoderKit.swift
cp "$kit/libSimBLEDecoderKit.dylib" "$app/Contents/Frameworks/"

xcrun --sdk macosx swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.4" -I "$kit" -L "$kit" -lSimBLEDecoderKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$app/Contents/MacOS/SimBLE" App/*.swift

# Self-contained Decoders/<name>/ become built-in plugins. Ones with a `sources` file depend on code
# elsewhere and are installed as user plugins instead; see make-decoder.sh.
for decoder in Decoders/*/; do
    [ -f "$decoder/sources" ] && continue
    ./make-decoder.sh "$(basename "$decoder")" "$app/Contents/PlugIns" > /dev/null
done

simulator_target="$arch-apple-ios15.0-simulator"
xcrun --sdk iphonesimulator clang -dynamiclib -O2 -Wall -Wextra \
    -target "$simulator_target" -framework CoreFoundation \
    -install_name @rpath/libSimBLELoader.dylib \
    -o "$app/Contents/Resources/libSimBLELoader.dylib" Loader/SimBLELoader.c
xcrun --sdk iphonesimulator clang -dynamiclib -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -target "$simulator_target" -framework Foundation -framework CoreBluetooth \
    -install_name @rpath/libSimBLEShim.dylib \
    -o "$app/Contents/Resources/libSimBLEShim.dylib" Shim/SimBLEShim.m
cp lldb/sim_ble_inject.py "$app/Contents/Resources/"

codesign --force --sign - "$app/Contents/Resources/libSimBLELoader.dylib" "$app/Contents/Resources/libSimBLEShim.dylib" \
    "$app/Contents/Frameworks/libSimBLEDecoderKit.dylib"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${identity:--}" "$app"
echo "Built $(pwd)/$app (signed with ${identity:-ad-hoc})"
