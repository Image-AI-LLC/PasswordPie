#!/bin/bash
# Build the App Store package: sandboxed, signed with the Mac App Store certificates, one distribution profile embedded
# per bundle, checked here the way docs/CHANNELS.md says. With --upload it also sends the build to App Store Connect.
#
# Profiles: Mac App Store distribution profiles for com.passwordpie, com.passwordpie.autofill and com.passwordpie.safari.
# Pass them as MAS_APP_PROFILE, MAS_AUTOFILL_PROFILE and MAS_SAFARI_PROFILE, or install them (double-click, or copy into
# ~/Library/MobileDevice/Provisioning Profiles) and the script finds them by bundle ID.
#
# Upload: `Scripts/release-mas.sh --upload` wraps the signed app in an .xcarchive and hands it to
# `xcodebuild -exportArchive`, which signs in as the Apple ID in Xcode > Settings > Accounts. No password is typed or
# passed. Without --upload the package stays in build/mas-dist for Transporter or a later run.
# Output: build/mas-dist/PasswordPie-<version>-<build>.pkg
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=2S468LUF8V
MAS_SIGN="${MAS_SIGN:-3rd Party Mac Developer Application: Image AI, LLC ($TEAM)}"
MAS_INSTALLER="${MAS_INSTALLER:-3rd Party Mac Developer Installer: Image AI, LLC ($TEAM)}"
UPLOAD=0
[[ "${1:-}" == "--upload" ]] && UPLOAD=1
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/PasswordPieApp/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/PasswordPieApp/Info.plist)
OUT=build/mas-dist
APP="$OUT/PasswordPie.app"
PKG="$OUT/PasswordPie-$VERSION-$BUILD.pkg"
BIN="$APP/Contents/MacOS/PasswordPie"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "release-mas: $*" >&2; exit 1; }

# profile_value <profile> <PlistBuddy key>
profile_value() {
  security cms -D -i "$1" > "$WORK/profile.plist" 2>/dev/null || fail "cannot read the profile $1"
  /usr/libexec/PlistBuddy -c "Print :$2" "$WORK/profile.plist" 2>/dev/null
}

# A Mac App Store distribution profile for this bundle ID that has not expired, or nothing.
find_profile() {
  local wanted="$TEAM.$1" file
  for file in "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile \
              "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile; do
    [[ -f "$file" ]] || continue
    [[ "$(profile_value "$file" Entitlements:com.apple.application-identifier)" == "$wanted" ]] || continue
    profile_value "$file" ProvisionedDevices >/dev/null && continue   # a development profile
    check_profile "$file" "$1" 2>/dev/null && { echo "$file"; return; }
  done
}

# check_profile <profile> <bundle id>: distribution, this bundle and team, not expired, made for the signing certificate.
check_profile() {
  local file="$1" id="$2" expires cert
  [[ "$(profile_value "$file" Entitlements:com.apple.application-identifier)" == "$TEAM.$id" ]] \
    || fail "$file is not for $TEAM.$id"
  ! profile_value "$file" ProvisionedDevices >/dev/null || fail "$file lists devices: it is a development profile"
  expires=$(date -j -f "%a %b %d %T %Z %Y" "$(profile_value "$file" ExpirationDate)" +%s)
  (( expires > $(date +%s) )) || fail "$file has expired"
  # The certificate in the keychain must be one the profile was made for.
  cert=$(security find-certificate -c "$MAS_SIGN" -Z | awk '/SHA-1/ {print $3}')
  [[ -n "$cert" ]] || fail "no \"$MAS_SIGN\" certificate in the keychain"
  python3 -I -c 'import hashlib, plistlib, sys
for der in plistlib.load(open(sys.argv[1], "rb"))["DeveloperCertificates"]:
    print(hashlib.sha1(der).hexdigest().upper())' "$WORK/profile.plist" | grep -qx "$cert" \
    || fail "$file was not made for the certificate \"$MAS_SIGN\""
}

MAS_APP_PROFILE="${MAS_APP_PROFILE:-$(find_profile com.passwordpie)}"
MAS_AUTOFILL_PROFILE="${MAS_AUTOFILL_PROFILE:-$(find_profile com.passwordpie.autofill)}"
MAS_SAFARI_PROFILE="${MAS_SAFARI_PROFILE:-$(find_profile com.passwordpie.safari)}"
for pair in "com.passwordpie:$MAS_APP_PROFILE" "com.passwordpie.autofill:$MAS_AUTOFILL_PROFILE" "com.passwordpie.safari:$MAS_SAFARI_PROFILE"; do
  id="${pair%%:*}"; file="${pair#*:}"
  [[ -n "$file" ]] || fail "no Mac App Store distribution profile for $id: make one on developer.apple.com and install it"
  check_profile "$file" "$id"
done
[[ "$(profile_value "$MAS_AUTOFILL_PROFILE" Entitlements:com.apple.developer.authentication-services.autofill-credential-provider)" == "true" ]] \
  || fail "the AutoFill profile lacks AutoFill Credential Provider: turn it on for com.passwordpie.autofill and make the profile again"

# 1. Build, sign and package.
make dist-mas MAS_SIGN="$MAS_SIGN" MAS_INSTALLER="$MAS_INSTALLER" \
  MAS_APP_PROFILE="$MAS_APP_PROFILE" MAS_AUTOFILL_PROFILE="$MAS_AUTOFILL_PROFILE" MAS_SAFARI_PROFILE="$MAS_SAFARI_PROFILE"
mv "$OUT/PasswordPie.pkg" "$PKG"

# 2. Checks (docs/CHANNELS.md). Each prints what it found and stops the release when it is wrong.
expect() { # expect <label> <wanted> <found>
  if [[ "$2" == "$3" ]]; then echo "ok    $1"; else fail "$1: expected $2, found $3"; fi
}
codesign --verify --deep --strict "$APP"
for code in "$APP" "$APP/Contents/PlugIns/PasswordPieAutoFill.appex" "$APP/Contents/PlugIns/PasswordPieSafari.appex"; do
  codesign -d --entitlements :- "$code" 2>/dev/null > "$WORK/ents.plist"
  expect "$(basename "$code") sandboxed" true "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$WORK/ents.plist")"
  expect "$(basename "$code") signed by" "Authority=$MAS_SIGN" "$(codesign -dvv "$code" 2>&1 | grep -m1 '^Authority=')"
  expect "$(basename "$code") profile" yes "$([[ -f "$code/Contents/embedded.provisionprofile" ]] && echo yes || echo no)"
done
codesign -d --entitlements :- "$APP" 2>/dev/null > "$WORK/ents.plist"
expect "no network.client" 0 "$(grep -c network.client "$WORK/ents.plist" || true)"
expect "only the app in Contents/MacOS (no updater, no Chrome host)" PasswordPie "$(ls "$APP/Contents/MacOS")"
expect "no Chrome password reader" 0 "$(strings -a "$BIN" | grep -ci -e 'safe storage' -e saltysalt || true)"
expect "no debug preview or mock site" 0 "$(strings -a "$BIN" | grep -c -e PASSWORDPIE_PREMIUM_PREVIEW -e PASSWORDPIE_SITE_URL || true)"
expect "no account or site API" 0 "$(strings -a "$BIN" | grep -c -e api/premium -e app/sign-in -e api/auth || true)"
expect "no updater code" 0 "$(strings -a "$BIN" | grep -c -e api.github.com -e PasswordPieUpdater -e updateAutomatically || true)"
expect "Safari extension asks no site API" "" "$(grep -rlE 'api/premium|api/auth' "$APP/Contents/PlugIns/PasswordPieSafari.appex/Contents/Resources" || true)"
expect "version" "$VERSION ($BUILD)" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
for plist in "$APP/Contents/PlugIns/PasswordPieAutoFill.appex/Contents/Info.plist" "$APP/Contents/PlugIns/PasswordPieSafari.appex/Contents/Info.plist"; do
  expect "$(basename "$(dirname "$(dirname "$plist")")") version" "$VERSION ($BUILD)" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
done
expect "App Store category" public.app-category.productivity "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$APP/Contents/Info.plist")"
pkgutil --check-signature "$PKG" | tee "$WORK/pkgsig.txt"
grep -q "$MAS_INSTALLER" "$WORK/pkgsig.txt" || fail "the package is not signed by \"$MAS_INSTALLER\""
(cd "$OUT" && shasum -a 256 "$(basename "$PKG")" | tee "$(basename "$PKG").sha256")
echo "Built $PKG"

(( UPLOAD )) || exit 0

# 3. Upload through Xcode's account: an .xcarchive around the signed app, exported straight to App Store Connect.
ARCHIVE="$OUT/PasswordPie.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$ARCHIVE/Products/Applications"
ditto "$APP" "$ARCHIVE/Products/Applications/PasswordPie.app"
/usr/libexec/PlistBuddy \
  -c "Add :ArchiveVersion integer 2" \
  -c "Add :CreationDate date $(date -u '+%a %b %d %T GMT %Y')" \
  -c "Add :Name string PasswordPie" \
  -c "Add :SchemeName string PasswordPie" \
  -c "Add :ApplicationProperties dict" \
  -c "Add :ApplicationProperties:ApplicationPath string Applications/PasswordPie.app" \
  -c "Add :ApplicationProperties:CFBundleIdentifier string com.passwordpie" \
  -c "Add :ApplicationProperties:CFBundleShortVersionString string $VERSION" \
  -c "Add :ApplicationProperties:CFBundleVersion string $BUILD" \
  -c "Add :ApplicationProperties:SigningIdentity string $MAS_SIGN" \
  -c "Add :ApplicationProperties:Team string $TEAM" \
  "$ARCHIVE/Info.plist"
OPTIONS="$WORK/ExportOptions.plist"
/usr/libexec/PlistBuddy \
  -c "Add :method string app-store-connect" \
  -c "Add :destination string upload" \
  -c "Add :teamID string $TEAM" \
  -c "Add :signingStyle string manual" \
  -c "Add :signingCertificate string $MAS_SIGN" \
  -c "Add :installerSigningCertificate string $MAS_INSTALLER" \
  -c "Add :provisioningProfiles dict" \
  -c "Add :provisioningProfiles:com.passwordpie string $(profile_value "$MAS_APP_PROFILE" UUID)" \
  -c "Add :provisioningProfiles:com.passwordpie.autofill string $(profile_value "$MAS_AUTOFILL_PROFILE" UUID)" \
  -c "Add :provisioningProfiles:com.passwordpie.safari string $(profile_value "$MAS_SAFARI_PROFILE" UUID)" \
  -c "Add :manageAppVersionAndBuildNumber bool false" \
  -c "Add :uploadSymbols bool false" \
  "$OPTIONS"
# exportArchive looks profiles up by UUID in Xcode's folder.
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES"
for file in "$MAS_APP_PROFILE" "$MAS_AUTOFILL_PROFILE" "$MAS_SAFARI_PROFILE"; do
  target="$PROFILES/$(profile_value "$file" UUID).provisionprofile"
  [[ -f "$target" ]] || cp "$file" "$target"
done
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$OUT/upload" \
  2>&1 | tee "$OUT/upload.log"
grep -q "EXPORT SUCCEEDED\|Upload succeeded\|Uploaded" "$OUT/upload.log" || fail "the upload failed, see $OUT/upload.log"
echo "Uploaded PasswordPie $VERSION ($BUILD) to App Store Connect; it shows under TestFlight once Apple has processed it."
