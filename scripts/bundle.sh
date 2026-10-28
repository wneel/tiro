#!/bin/bash
# Builds Tiro in release and assembles a signed dist/Tiro.app.
#
# SIGN_IDENTITY: a certificate SHA-1 hash, or "-" for ad-hoc. When unset, the first
# "Developer ID Application" identity is used, then the first "Apple Development" one,
# then ad-hoc. Identities are always passed by hash, since names can be ambiguous.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SCRATCH="$ROOT/.build.nosync"
DIST="$ROOT/dist"
APP="$DIST/Tiro.app"
CONTENTS="$APP/Contents"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# MARK: Build

ARCHS="arm64 x86_64"
log "Building release (universal: $ARCHS)"
if swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"; then
	BIN=$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)
else
	ARCHS=$(uname -m)
	log "Universal build failed, building for $ARCHS only"
	swift build -c release --scratch-path "$SCRATCH"
	BIN=$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)
fi
[ -x "$BIN/Tiro" ] || fail "no executable at $BIN/Tiro"

FRAMEWORK="$BIN/whisper.framework"
if [ ! -d "$FRAMEWORK" ]; then
	FRAMEWORK=$(find "$SCRATCH/artifacts" -type d -path '*/macos-*/whisper.framework' -print -quit)
fi
[ -n "$FRAMEWORK" ] && [ -d "$FRAMEWORK" ] || fail "whisper.framework (macOS slice) not found"

# MARK: Assemble

log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchAgents"

cp "$BIN/Tiro" "$CONTENTS/MacOS/Tiro"
ditto "$FRAMEWORK" "$CONTENTS/Frameworks/whisper.framework"
# Headers and module maps are build-time only.
rm -rf "$CONTENTS/Frameworks/whisper.framework/Headers" \
	"$CONTENTS/Frameworks/whisper.framework/Modules" \
	"$CONTENTS/Frameworks/whisper.framework/Versions/A/Headers" \
	"$CONTENTS/Frameworks/whisper.framework/Versions/A/Modules"

cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp Resources/org.animalert.tiro.agent.plist "$CONTENTS/Library/LaunchAgents/"

xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$CONTENTS/Resources"
xcrun xcstringstool compile Resources/InfoPlist.xcstrings --output-directory "$CONTENTS/Resources"
# The source language needs its folder too, so macOS lists English as supported.
mkdir -p "$CONTENTS/Resources/en.lproj"

if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
else
	log "No Resources/AppIcon.icns: the app uses the generic icon"
fi

for plist in "$CONTENTS/Info.plist" "$CONTENTS/Library/LaunchAgents/org.animalert.tiro.agent.plist"; do
	plutil -lint -s "$plist" || fail "invalid plist: $plist"
done

# MARK: Sign

identities=$(security find-identity -v -p codesigning || true)
first_hash() { printf '%s\n' "$identities" | awk -v kind="$1" 'index($0, "\"" kind) { print $2; exit }'; }

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
	IDENTITY=$(first_hash "Developer ID Application")
	[ -n "$IDENTITY" ] || IDENTITY=$(first_hash "Apple Development")
	[ -n "$IDENTITY" ] || IDENTITY="-"
fi

if [ "$IDENTITY" = "-" ]; then
	KIND="ad-hoc"
elif printf '%s\n' "$identities" | grep -F "$IDENTITY" | grep -q '"Developer ID Application'; then
	KIND="Developer ID"
else
	KIND="development"
fi

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$KIND" = "Developer ID" ]; then
	SIGN_FLAGS+=(--options runtime --timestamp)
elif [ "$KIND" = "development" ]; then
	SIGN_FLAGS+=(--options runtime --timestamp=none)
else
	# Library validation would reject the ad-hoc framework under the hardened runtime.
	SIGN_FLAGS+=(--timestamp=none)
fi

log "Signing ($KIND, $IDENTITY)"
xattr -cr "$APP"
codesign "${SIGN_FLAGS[@]}" "$CONTENTS/Frameworks/whisper.framework"
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/Tiro.entitlements "$APP"
codesign --verify --deep --strict "$APP" || fail "signature does not verify"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
log "Built $APP $VERSION ($ARCHS, $KIND)"
