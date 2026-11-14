#!/bin/bash
# Build the direct-download DMG: Developer ID signed, notarized and stapled (app and DMG).
#
# Notarization signs in with a notarytool keychain profile, NOTARY_PROFILE (default passwordpie-notary), so the
# app-specific password is on no command line while the script waits for Apple, and nobody types it per release.
# The profile is made once, either by hand:
#     xcrun notarytool store-credentials passwordpie-notary --apple-id <id> --team-id <team>     (asks for the password)
# or by this script, the first time it finds APPLE_ID, APPLE_PASSWORD (an app-specific password) and APPLE_TEAM_ID in
# the environment or in the file named by NOTARY_ENV (KEY=value lines). After that run neither is needed.
# `Scripts/release-direct.sh --check` does only this sign-in and says whether it works.
# Output: build/direct/PasswordPie-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-passwordpie-notary}"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  if [[ -n "${NOTARY_ENV:-}" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        APPLE_ID|APPLE_PASSWORD|APPLE_TEAM_ID)
          value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
          export "$key=$value" ;;
      esac
    done < "$NOTARY_ENV"
  fi
  hint="no working notarytool profile \"$PROFILE\": make it with xcrun notarytool store-credentials, or set APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID (or NOTARY_ENV) once"
  : "${APPLE_ID:?$hint}" "${APPLE_PASSWORD:?$hint}" "${APPLE_TEAM_ID:?$hint}"
  # The one moment the password is an argument: storing it. notarytool checks it with Apple before it saves.
  xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_PASSWORD" >/dev/null
  unset APPLE_PASSWORD
  echo "saved the notarytool profile \"$PROFILE\" in the keychain" >&2
fi
if [[ "${1:-}" == "--check" ]]; then
  echo "notarization sign-in works with the keychain profile \"$PROFILE\""
  exit 0
fi

DEVID="${DEVID:-Developer ID Application: Image AI, LLC (2S468LUF8V)}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/PasswordPieApp/Info.plist)
OUT=build/direct
APP="$OUT/PasswordPie.app"
DMG="$OUT/PasswordPie-$VERSION.dmg"
STAGE="$OUT/dmg-stage"

notarize() {
  local log="$OUT/notary-$(basename "$1").json"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m --output-format json > "$log"
  if ! grep -q '"status" *: *"Accepted"' "$log"; then
    echo "notarization failed for $1, see $log" >&2
    local id; id=$(sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' "$log" | head -1)
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

# 1. Signed app (hardened runtime), zipped for notarization.
make dist-direct DEVID="$DEVID"
codesign --verify --deep --strict "$APP"

# 2. Notarize and staple the app, so a copy dragged out of the DMG passes Gatekeeper offline.
notarize "$OUT/PasswordPie.zip"
xcrun stapler staple "$APP"

# 3. DMG with an Applications shortcut, signed, notarized and stapled.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PasswordPie.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PasswordPie" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$DEVID" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# 4. Check what a downloader's Mac will check.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "Built $DMG"
