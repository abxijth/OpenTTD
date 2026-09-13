#!/bin/sh
# This file is part of OpenTTD.
# OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
# OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.

# Assemble an iOS .app bundle from a configured/built OpenTTD tree.
#
# Usage:
#   os/ios/build_app.sh <build-directory> [output-directory]
#
# The build directory must have been configured with
# os/ios/toolchain_ios.cmake and built. The produced OpenTTD.app is written to
# <output-directory>/OpenTTD.app (default: the build directory's parent).

set -e

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <build-directory> [output-directory]" >&2
    exit 1
fi

BUILD_DIR="$(cd "$1" && pwd)"
mkdir -p "${2:-$(dirname "$BUILD_DIR")}"
OUTPUT_DIR="$(cd "${2:-$(dirname "$BUILD_DIR")}" && pwd)"

SOURCE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BINARY_NAME="${BINARY_NAME:-openttd}"

BUNDLE_DIR="$OUTPUT_DIR/OpenTTD.app"
GAME_DATA_DIR="$BUNDLE_DIR/Data"    # location OpenTTD looks for game data on iOS

# OpenTTD generates the base set and the language files inside the build
# directory; the AI / GameScript files live in the source tree under bin/.
copy_dir() {
    if [ -d "$1" ]; then
        cp -R "$1/." "$GAME_DATA_DIR/"
    fi
}

echo "Assembling $BUNDLE_DIR..."

rm -rf "$BUNDLE_DIR"
mkdir -p "$GAME_DATA_DIR"

# The OpenTTD iOS binary. When CMake is configured for a GUI (bundle) target it
# places the binary inside an "<name>.app" directory next to the plain binary.
APP_BINARY="$BUILD_DIR/$BINARY_NAME"
if [ ! -x "$APP_BINARY" ]; then
    APP_BINARY="$(find "$BUILD_DIR" -maxdepth 4 -type f -name "$BINARY_NAME" -path '*.app/*' | head -1)"
fi
if [ ! -x "$APP_BINARY" ]; then
    echo "Could not find the OpenTTD binary in $BUILD_DIR" >&2
    exit 1
fi
cp "$APP_BINARY" "$BUNDLE_DIR/openttd"
chmod +x "$BUNDLE_DIR/openttd"

# Game data: baseset, lang and standard subdirectories.
copy_dir "$BUILD_DIR/baseset"
copy_dir "$BUILD_DIR/lang"

# AI, GameScripts and language script directories ship from the source tree.
copy_dir "$SOURCE_DIR/bin/ai"
copy_dir "$SOURCE_DIR/bin/game"
copy_dir "$SOURCE_DIR/bin/scripts"

# Info.plist.
CURRENT_YEAR="$(date +%Y)"
VERSION="$(git -C "$SOURCE_DIR" describe --tags --always 2>/dev/null || echo "0.0.0")"
sed -e "s/#OPENTTD_VERSION#/$VERSION/g" \
    -e "s/#CURRENT_YEAR#/$CURRENT_YEAR/g" \
    "$SOURCE_DIR/os/ios/Info.plist.in" > "$BUNDLE_DIR/Info.plist"

# Icon: use the largest PNG artwork as a fallback icon.
if [ -f "$SOURCE_DIR/media/openttd.1024.png" ]; then
    cp "$SOURCE_DIR/media/openttd.1024.png" "$BUNDLE_DIR/OpenTTD.png"
fi

echo "Done: $BUNDLE_DIR"
echo "Deploy with: xcrun simctl install booted $BUNDLE_DIR (simulator)"
echo "              or actool/Asset Catalog for a device (see media/)."