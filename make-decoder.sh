#!/bin/sh
# Builds a decoder plugin into <name>.dylib and installs it where SimBLE loads plugins; then use Reload
# (or Add Plugin when building to another folder).
#
# Usage: make-decoder.sh <plugin> [output dir]
#   <plugin> is a folder name under Decoders/ or a path to a plugin folder anywhere, so plugins with
#   private sources can live outside this repository.
#
# A plugin folder holds its adapter *.swift files and, optionally, a `sources` file listing more Swift
# files compiled into the same module, one per line. Relative lines resolve against SOURCES_ROOT if set,
# else a `root <path>` line in the file, else the plugin folder. Lines starting with # are comments.
# Plugins build in Swift 6 mode unless DECODER_SWIFT_VERSION says otherwise.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
plugin="${1:?usage: make-decoder.sh <plugin name or folder> [output dir]}"
output="${2:-$HOME/Library/Application Support/SimBLE/Decoders}"
[ -d "$plugin" ] || plugin="$here/Decoders/$plugin"
[ -d "$plugin" ] || { echo "No plugin folder: $1" >&2; exit 1; }
plugin="$(cd "$plugin" && pwd)"
name="$(basename "$plugin")"
kit="$here/.build/DecoderKit"
[ -f "$kit/libSimBLEDecoderKit.dylib" ] || { echo "Run build.sh first: it builds the decoder interface." >&2; exit 1; }

set -- "$plugin"/*.swift
if [ -f "$plugin/sources" ]; then
    root="$plugin"
    file_root="$(sed -n 's/^root[[:space:]]*//p' "$plugin/sources" | head -n 1)"
    [ -n "$file_root" ] && root="$(eval echo "$file_root")"
    root="${SOURCES_ROOT:-$root}"
    while IFS= read -r line; do
        case "$line" in ''|'#'*|'root '*) continue ;; /*) file="$line" ;; *) file="$root/$line" ;; esac
        [ -f "$file" ] || { echo "Missing source: $file" >&2; exit 1; }
        set -- "$@" "$file"
    done < "$plugin/sources"
fi

mkdir -p "$output"
arch="$(uname -m)"
xcrun --sdk macosx swiftc -O -swift-version "${DECODER_SWIFT_VERSION:-6}" -parse-as-library \
    -target "$arch-apple-macos14.4" -module-name "${name}Decoder" \
    -I "$kit" -L "$kit" -lSimBLEDecoderKit -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -emit-library -o "$output/$name.dylib" "$@"
codesign --force --sign - "$output/$name.dylib" 2>/dev/null
echo "Built $output/$name.dylib"
