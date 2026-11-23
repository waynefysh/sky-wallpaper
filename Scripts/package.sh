#!/bin/bash
# Packages Sky into ./dist. Three ways:
#
# 1. Personal build (no Apple account; right-click > Open the first time):
#      Scripts/package.sh
#
# 2. Developer ID: the full app, signed and notarised, to sell or share directly as a DMG:
#      SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=sky Scripts/package.sh
#    "sky" is a notary profile saved once with:
#      xcrun notarytool store-credentials sky --apple-id <your Apple ID> --team-id TEAMID
#
# 3. Mac App Store: sandboxed, without the Dock effects, as a .pkg to upload with Transporter:
#      APP_STORE=1 TEAM_ID=TEAMID \
#      SIGN_ID="Apple Distribution: Your Name (TEAMID)" \
#      INSTALLER_ID="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
#      PROFILE=~/Downloads/Sky_Mac_App_Store.provisionprofile Scripts/package.sh
#
# Other settings: VERSION (default 1.0), BUNDLE_ID (default com.waynefysh.sky; must match
# the App ID in your developer account), UNIVERSAL=1 for an Intel + Apple silicon build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="${BUNDLE_ID:-com.waynefysh.sky}"
SIGN_ID="${SIGN_ID:--}"           # "-" signs ad hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP_STORE="${APP_STORE:-0}"
DIST=dist
APP="$DIST/Sky.app"

BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
if [[ "$APP_STORE" == 1 ]]; then
    : "${TEAM_ID:?Set TEAM_ID for an App Store build}"
    : "${PROFILE:?Set PROFILE to the Mac App Store provisioning profile}"
    : "${INSTALLER_ID:?Set INSTALLER_ID to your Mac Installer Distribution certificate}"
    [[ "$SIGN_ID" != "-" ]] || { echo "Set SIGN_ID to your Apple Distribution certificate"; exit 1; }
    # Built separately so it never mixes with the full build.
    BUILD_ARGS+=(--scratch-path .build/appstore -Xswiftc -DAPP_STORE)
fi

echo "==> Building ($([[ "$APP_STORE" == 1 ]] && echo "Mac App Store" || echo "full"))"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SkyWallpaper" "$APP/Contents/MacOS/SkyWallpaper"
# SkyCore's star catalogue and Moon map. Signing only allows it under Contents/Resources.
cp -R "$BIN_DIR/SkyWallpaper_SkyCore.bundle" "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing ($([[ "$SIGN_ID" == "-" ]] && echo "ad hoc" || echo "$SIGN_ID"))"
if [[ "$APP_STORE" == 1 ]]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENT="$(mktemp -d)/Sky.entitlements"
    cp Resources/AppStore.entitlements "$ENT"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENT"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENT"
    codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
elif [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [[ "$APP_STORE" == 1 ]]; then
    PKG="$DIST/Sky-$VERSION-AppStore.pkg"
    echo "==> Installer package"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
    echo "Done: $PKG (upload it with the Transporter app)"
    exit 0
fi

DMG="$DIST/Sky-$VERSION.dmg"
echo "==> Disk image"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sky" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [[ "$SIGN_ID" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notarising (takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Done: $APP and $DMG"
