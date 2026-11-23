#!/usr/bin/env bash
# Package a signed .app, sign and notarize the .dmg, and staple the ticket.
#   Requires: ./scripts/build.sh already run with SIGN_IDENTITY="Developer ID Application"
#             and the same Developer ID identity available in the keychain.
#   SIGN_IDENTITY may override the identity read from the app signature.
#   Credentials, either:
#     NOTARY_KEYCHAIN_PROFILE … profile saved with `xcrun notarytool store-credentials`
#                               (preferred locally: the password never appears in `ps`)
#   or an App Store Connect API key (no secret on the command line):
#     NOTARY_KEY_PATH   … path to the AuthKey_XXXX.p8 file
#     NOTARY_KEY_ID     … key ID
#     NOTARY_KEY_ISSUER … issuer UUID
#   or all of:
#     APPLE_TEAM_ID    … Team ID (10 chars)
#     NOTARY_APPLE_ID  … Apple ID for notarization (email)
#     NOTARY_PASSWORD  … app-specific password (created at appleid.apple.com)
#                        (passed as a notarytool argument; fine on an ephemeral CI runner)
#   Usage: ./scripts/notarize.sh [path/to/"Spacebar 3D.app"]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-build/Build/Products/Release/Spacebar 3D.app}"
DMG="Spacebar3D.dmg"

if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  AUTH_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is not set}"
  : "${NOTARY_KEY_ISSUER:?NOTARY_KEY_ISSUER is not set}"
  AUTH_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER")
else
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"
  : "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is not set}"
  : "${NOTARY_PASSWORD:?NOTARY_PASSWORD is not set}"
  AUTH_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

if [ ! -d "$APP" ]; then
  echo "error: $APP not found. Run build.sh with signing first." >&2
  exit 1
fi

echo "==> Verify the signature"
DEVELOPER_ID_REQUIREMENT='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
codesign --verify --deep --strict --verbose=2 -R="$DEVELOPER_ID_REQUIREMENT" "$APP"
DMG_SIGN_ID="${SIGN_IDENTITY:-}"
if [ -z "$DMG_SIGN_ID" ]; then
  DMG_SIGN_ID="$(codesign --display --verbose=4 "$APP" 2>&1 | awk '/^Authority=Developer ID Application:/ && !seen++ { sub(/^Authority=/, ""); print }')"
fi
: "${DMG_SIGN_ID:?Developer ID Application identity not found in the app signature}"

echo "==> Create the .dmg: $DMG"
WORK="$(mktemp -d "$ROOT/.spacebar3d-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
IMAGE="$WORK/$DMG"
mkdir "$STAGE"
# Stage the app next to an Applications link. ditto preserves the signature.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Spacebar 3D" -srcfolder "$STAGE" -format UDZO "$IMAGE"
codesign --sign "$DMG_SIGN_ID" --timestamp "$IMAGE"
codesign --verify --verbose=2 -R="$DEVELOPER_ID_REQUIREMENT" "$IMAGE"

echo "==> Submit for notarization (wait until done)"
RESULT="$WORK/notary.json"
if xcrun notarytool submit "$IMAGE" "${AUTH_ARGS[@]}" --wait --output-format json > "$RESULT" &&
  [ "$(plutil -extract status raw -expect string -o - "$RESULT" 2>/dev/null)" = Accepted ]; then
  cat "$RESULT"
else
  cat "$RESULT" >&2
  echo "error: notarization did not pass" >&2
  SUB_ID="$(plutil -extract id raw -expect string -o - "$RESULT" 2>/dev/null || true)"
  [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" "${AUTH_ARGS[@]}" || true
  exit 1
fi

echo "==> Staple and validate"
xcrun stapler staple "$IMAGE"
xcrun stapler validate "$IMAGE"
spctl -a -t open --context context:primary-signature -v "$IMAGE"
mv -f "$IMAGE" "$DMG"

echo "==> Done: $ROOT/$DMG (ready to distribute)"
