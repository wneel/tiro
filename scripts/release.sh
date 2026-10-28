#!/bin/bash
# Builds, signs and notarizes dist/Tiro-<version>.dmg. Uploads nothing: publishing the
# GitHub release is a manual step (see README).
#
# Needs a "Developer ID Application" identity in the keychain and a notarytool profile:
#   xcrun notarytool store-credentials tiro-notary --apple-id <id> --team-id <team>
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
PROFILE="${NOTARY_PROFILE:-tiro-notary}"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

identities=$(security find-identity -v -p codesigning || true)
if [ -n "${SIGN_IDENTITY:-}" ]; then
	printf '%s\n' "$identities" | grep -F "$SIGN_IDENTITY" | grep -q '"Developer ID Application' \
		|| fail "SIGN_IDENTITY $SIGN_IDENTITY is not a Developer ID Application identity"
	IDENTITY="$SIGN_IDENTITY"
else
	IDENTITY=$(printf '%s\n' "$identities" | awk 'index($0, "\"Developer ID Application") { print $2; exit }')
	[ -n "$IDENTITY" ] || fail "no Developer ID Application identity in the keychain"
fi

SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
APP="$ROOT/dist/Tiro.app"
DMG="$ROOT/dist/Tiro-$VERSION.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/tiro-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

log "Creating $DMG"
ditto "$APP" "$STAGING/Tiro.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Tiro" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

log "Notarizing (profile $PROFILE), this takes a few minutes"
OUTPUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1) || true
printf '%s\n' "$OUTPUT"
if ! printf '%s\n' "$OUTPUT" | grep -q 'status: Accepted'; then
	ID=$(printf '%s\n' "$OUTPUT" | awk '/^ *id:/ { print $2; exit }')
	[ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
	fail "notarization was not accepted"
fi

log "Stapling"
xcrun stapler staple "$DMG"

log "Verifying"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
spctl -a -vv "$APP"

log "Ready: $DMG"
printf 'Publish it with:\n  gh release create v%s "%s" --title "Tiro %s" --notes-file <notes.md>\n' "$VERSION" "$DMG" "$VERSION"
