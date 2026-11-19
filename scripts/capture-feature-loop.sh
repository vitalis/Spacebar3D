#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SPACEBAR3D_SCREENSHOTS=0 SPACEBAR3D_FEATURE_LOOP=1 exec "$script_dir/capture-media.sh" "$@"
