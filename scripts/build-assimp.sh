#!/bin/bash
# Builds the Assimp library the native readers for FBX and 3DS link, as
# Packages/Spacebar3DKit/Vendor/Assimp.xcframework. The result is not kept in git; run this
# once after cloning, and again when the pinned version below changes.
#
#   scripts/build-assimp.sh              fetch the pinned commit and build
#   ASSIMP_SRC=/path/to/assimp scripts/build-assimp.sh
#                                        build an existing checkout (it must be at the pinned commit)
#
# Needs cmake and ninja. Static, arm64, only the FBX and 3DS importers, no exporters, no
# Draco, the system zlib.
set -euo pipefail

ASSIMP_TAG="v6.0.6"
ASSIMP_COMMIT="a79ff6bbce54d3e01186a918dc6374ed55317426"
DEPLOYMENT_TARGET="26.0"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Packages/Spacebar3DKit/Vendor/Assimp.xcframework"
work="$(mktemp -d "${TMPDIR:-/tmp}/p3d-assimp.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for tool in cmake ninja xcodebuild git; do
  command -v "$tool" >/dev/null || { echo "error: $tool is needed" >&2; exit 1; }
done

src="${ASSIMP_SRC:-}"
if [ -z "$src" ]; then
  src="$work/assimp"
  git clone --quiet --depth 1 --branch "$ASSIMP_TAG" https://github.com/assimp/assimp.git "$src"
fi
actual="$(git -C "$src" rev-parse HEAD)"
if [ "$actual" != "$ASSIMP_COMMIT" ]; then
  echo "error: $src is at $actual, not the pinned $ASSIMP_COMMIT" >&2
  exit 1
fi

cmake -S "$src" -B "$work/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DASSIMP_NO_EXPORT=ON \
  -DASSIMP_BUILD_DRACO=OFF \
  -DASSIMP_BUILD_ZLIB=OFF \
  -DASSIMP_BUILD_TESTS=OFF \
  -DASSIMP_BUILD_ASSIMP_TOOLS=OFF \
  -DASSIMP_BUILD_SAMPLES=OFF \
  -DASSIMP_INSTALL=OFF \
  -DASSIMP_WARNINGS_AS_ERRORS=OFF \
  -DASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF \
  -DASSIMP_BUILD_FBX_IMPORTER=ON \
  -DASSIMP_BUILD_3DS_IMPORTER=ON \
  > "$work/cmake.log" 2>&1 || { tail -30 "$work/cmake.log" >&2; exit 1; }
cmake --build "$work/build" > "$work/build.log" 2>&1 || { tail -40 "$work/build.log" >&2; exit 1; }

lib="$(find "$work/build" -name 'libassimp*.a' | head -1)"
[ -f "$lib" ] || { echo "error: the build produced no library" >&2; exit 1; }

# The public headers and the generated config.h in one folder, with a module map that
# exposes the C interface to Swift and says what else to link.
headers="$work/headers"
mkdir -p "$headers/assimp"
cp -R "$src/include/assimp/." "$headers/assimp/"
cp "$work/build/include/assimp/config.h" "$headers/assimp/config.h"
[ -f "$work/build/include/assimp/revision.h" ] && cp "$work/build/include/assimp/revision.h" "$headers/assimp/revision.h"
rm -f "$headers/assimp/module.modulemap"
cat > "$headers/module.modulemap" <<'MAP'
module Assimp {
    header "assimp/cimport.h"
    header "assimp/scene.h"
    header "assimp/postprocess.h"
    header "assimp/cfileio.h"
    header "assimp/version.h"
    link "c++"
    link "z"
    export *
}
MAP

rm -rf "$out"
mkdir -p "$(dirname "$out")"
xcodebuild -create-xcframework -library "$lib" -headers "$headers" -output "$out" > "$work/xcframework.log" 2>&1 \
  || { cat "$work/xcframework.log" >&2; exit 1; }
echo "$ASSIMP_TAG $actual" > "$out/VERSION"
echo "built $out ($(du -sh "$out" | cut -f1)), Assimp $ASSIMP_TAG $actual"
