#!/usr/bin/env bash
# One-shot build script for Spacebar 3D.
#   Requires: full Xcode and xcodegen installed (and cmake and ninja the first time, for Assimp)
#   Usage: ./scripts/build.sh
#   SPACEBAR3D_BUILD_DIR overrides the derived data path.
#   SPACEBAR3D_BUILD_MEDIA_CAPTURE=1 enables the local media capture controls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Building an App Extension needs full Xcode. Even if xcode-select points at
# CommandLineTools, auto-detect and use full Xcode here.
if [ ! -d "$(xcode-select -p 2>/dev/null)/Platforms" ]; then
  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "==> Using full Xcode: $DEVELOPER_DIR"
  else
    echo "error: full Xcode not found. Install it from the App Store." >&2
    exit 1
  fi
fi

# The native readers link Assimp, which is built once and not kept in git.
if [ ! -d Packages/Spacebar3DKit/Vendor/Assimp.xcframework ]; then
  echo "==> Building Assimp (first run only)"
  ./scripts/build-assimp.sh
fi

echo "==> 1/3 Generate the Xcode project (xcodegen)"
# SKIP_XCODEGEN=1 reuses an already generated project (the release workflow generates
# it before the signing certificate is imported).
if [ "${SKIP_XCODEGEN:-}" = "1" ]; then
  [ -d Spacebar3D.xcodeproj ] || { echo "error: Spacebar3D.xcodeproj not found" >&2; exit 1; }
  echo "    (reusing Spacebar3D.xcodeproj)"
else
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Run 'brew install xcodegen'." >&2
    exit 1
  fi
  xcodegen generate
fi

# Signing mode is chosen via env vars:
#   local:        unset → the project's own settings (project.yml): the team's "Apple
#                 Development" identity, automatic signing. A team signature is required
#                 because the app and the extension share settings through an App Group;
#                 an ad-hoc ("-") build runs but cannot share settings.
#   distribution: SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=XXXXXXXXXX
SIGN_ID="${SIGN_IDENTITY:-}"
TEAM="${DEVELOPMENT_TEAM:-}"
SIGN_ARGS=()
if [ -n "$SIGN_ID" ]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM")
  # Notarization requires a secure timestamp (Hardened Runtime is enabled in project.yml).
  # Also, `xcodebuild build` auto-injects get-task-allow, which notarization rejects, so
  # CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO stops that injection (key for distribution).
  SIGN_ARGS+=(OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
  echo "==> 2/3 Build the app (signing: ${SIGN_ID} / team: ${TEAM})"
else
  echo "==> 2/3 Build the app (signing: the project's development identity)"
  # NOTE: building unsigned (CODE_SIGNING_ALLOWED=NO) means the extension won't register with pluginkit.
fi

BUILD_DIR="${SPACEBAR3D_BUILD_DIR:-build}"
CAPTURE_ARGS=()
if [ "${SPACEBAR3D_BUILD_MEDIA_CAPTURE:-}" = "1" ]; then
  CAPTURE_ARGS=(SPACEBAR3D_MEDIA_CAPTURE_CONDITION=SPACEBAR_MEDIA_CAPTURE)
fi

xcodebuild \
  -project Spacebar3D.xcodeproj \
  -scheme Spacebar3D \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  ${CAPTURE_ARGS[@]+"${CAPTURE_ARGS[@]}"} \
  build

APP="$BUILD_DIR/Build/Products/Release/Spacebar 3D.app"
echo "==> 3/3 Build complete: $APP"
if [ "${SPACEBAR3D_BUILD_MEDIA_CAPTURE:-}" = "1" ]; then
  exit 0
fi
echo
echo "Install and verify:"
echo "  1) Copy $APP to /Applications and launch it once"
echo "     (registers the Quick Look extension with macOS)"
echo "  2) Enable the extension: System Settings > General > Login Items & Extensions > Quick Look"
echo "  3) Reload Quick Look:  qlmanage -r && qlmanage -r cache"
echo "  4) Test:  qlmanage -p /path/to/model.glb  (any supported format)"
