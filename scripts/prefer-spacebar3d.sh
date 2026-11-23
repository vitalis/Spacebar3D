#!/bin/bash
# Make Finder's Space-bar preview use Spacebar 3D for OBJ, STL, PLY, USD and USDZ.
#
# macOS ships its own preview extensions for these types and prefers them over ours.
# This switches them off (or back on) for the current user with pluginkit. Nothing in
# the system is modified, and "off" restores the default.
#
#   scripts/prefer-spacebar3d.sh on      # OBJ, STL, PLY, USD and USDZ open in Spacebar 3D
#   scripts/prefer-spacebar3d.sh off     # back to macOS's own previews
#   scripts/prefer-spacebar3d.sh status
#
# While on, files only Apple's extensions handle lose their richer preview:
# MaterialX and Alembic fall back to a plain SceneKit preview, USDZ loses the AR view,
# and .reality files have no preview.
set -euo pipefail

OURS="com.vitalis.Spacebar3D.Extension"
APPLE=(
  "com.apple.HydraQLPreviewExtension"   # OBJ, STL (also PLY, USD, MaterialX, Alembic)
  "com.apple.RAQLPreviewExtension"      # USDZ (also .reality)
)

reset_quicklook() {
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  killall quicklookd >/dev/null 2>&1 || true
}

status() {
  pluginkit -m -A -v -p com.apple.quicklook.preview 2>/dev/null |
    grep -E "HydraQLPreviewExtension|RAQLPreviewExtension|${OURS}" |
    awk '{ state = ($1 == "-") ? "off" : "on "; print state, $0 }' | cut -c1-80
}

case "${1:-}" in
  on)
    pluginkit -e use -i "$OURS"
    for id in "${APPLE[@]}"; do pluginkit -e ignore -i "$id"; done
    reset_quicklook
    ;;
  off)
    for id in "${APPLE[@]}"; do pluginkit -e use -i "$id"; done
    reset_quicklook
    ;;
  status) ;;
  *)
    echo "usage: $0 on|off|status" >&2
    exit 2
    ;;
esac
status
