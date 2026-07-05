#!/bin/bash
set -euo pipefail

DMG_NAME="Savage Mod Player"
APP_NAME="Savage Mod Player.app"
VOL_NAME="Savage Mod Player"
BUILD_DIR="build"
RW_DMG="${BUILD_DIR}/dmg_rw.dmg"
FINAL_DMG="${BUILD_DIR}/${DMG_NAME}.dmg"
MOUNT_DIR="/Volumes/${VOL_NAME}"
NOTARIZE=0
FINDER_LAYOUT=1
NOTARY_PROFILE="${NOTARY_PROFILE:-SavageModPlayerNotary}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($APPLE_TEAM_ID)}"
SIGN_DMG="${SIGN_DMG:-auto}"

usage() {
    cat <<EOF
Usage: bash build_dmg.sh [--notarize] [--no-finder-layout]

  --notarize          Submit DMG with xcrun notarytool and staple ticket.
  --no-finder-layout  Skip Finder/AppleScript icon layout, useful on headless runs.

Environment:
  NOTARY_PROFILE      Keychain profile for notarytool (default: SavageModPlayerNotary).
  SIGN_DMG            auto/1/0, controls Developer ID signing of the DMG.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            NOTARIZE=1
            shift
            ;;
        --no-finder-layout)
            FINDER_LAYOUT=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

cleanup() {
    if hdiutil info | grep -Fq "$MOUNT_DIR"; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -f "$RW_DMG" "${BUILD_DIR}/DmgBg_1x.png" "${BUILD_DIR}/DmgBg_2x.png" "${BUILD_DIR}/DmgBackground.tiff"
    rm -rf "${BUILD_DIR}/dmg_temp"
}
trap cleanup EXIT

echo "=== Preparing DMG Build ==="
mkdir -p "$BUILD_DIR"
rm -f "$FINAL_DMG" "$RW_DMG"
rm -rf "${BUILD_DIR}/dmg_temp"
mkdir -p "${BUILD_DIR}/dmg_temp"

if [[ ! -d "$APP_NAME" ]]; then
    echo "ABBRUCH: ${APP_NAME} fehlt. Erst bash build_app.sh ausfuehren." >&2
    exit 1
fi

if codesign --verify --deep --strict "$APP_NAME" >/dev/null 2>&1; then
    echo "=== App signature valid ==="
else
    echo "WARNUNG: App ist nicht gueltig signiert. Notarisierung wird fehlschlagen."
fi

cp -R "${APP_NAME}" "${BUILD_DIR}/dmg_temp/"
ln -s /Applications "${BUILD_DIR}/dmg_temp/Applications"

sips -s format png -s dpiWidth 72 -s dpiHeight 72 -z 600 600 src/DmgBackground.png --out "${BUILD_DIR}/DmgBg_1x.png"
sips -s format png -s dpiWidth 144 -s dpiHeight 144 -z 1200 1200 src/DmgBackground.png --out "${BUILD_DIR}/DmgBg_2x.png"
tiffutil -cathidpicheck "${BUILD_DIR}/DmgBg_1x.png" "${BUILD_DIR}/DmgBg_2x.png" -out "${BUILD_DIR}/DmgBackground.tiff"

hdiutil create -size 80m -fs HFS+ -volname "${VOL_NAME}" -ov "$RW_DMG"

echo "=== Mounting DMG ==="
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" "$RW_DMG"

echo "=== Copying files to DMG ==="
cp -R "${BUILD_DIR}/dmg_temp/${APP_NAME}" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

mkdir -p "$MOUNT_DIR/.background"
cp "${BUILD_DIR}/DmgBackground.tiff" "$MOUNT_DIR/.background/DmgBackground.tiff"

if [[ "$FINDER_LAYOUT" == "1" ]]; then
    echo "=== Configuring DMG layout with AppleScript ==="
    osascript <<EOF
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 700, 700}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:DmgBackground.tiff"
        -- Position icons over the slots in the background image
        set position of item "${APP_NAME}" of container window to {180, 360}
        set position of item "Applications" of container window to {420, 360}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
else
    echo "=== Skipping Finder layout ==="
fi

echo "=== Unmounting DMG ==="
sleep 2
hdiutil detach "$MOUNT_DIR" || hdiutil detach -force "$MOUNT_DIR"

echo "=== Converting DMG to read-only ==="
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG"
hdiutil verify "$FINAL_DMG"

if [[ "$SIGN_DMG" != "0" ]]; then
    echo "=== Signing DMG ==="
    if security find-identity -v -p codesigning | grep -Fq "$CODESIGN_IDENTITY"; then
        codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$FINAL_DMG"
        codesign --verify --verbose=2 "$FINAL_DMG"
    elif [[ "$SIGN_DMG" == "1" ]]; then
        echo "ABBRUCH: Codesign-Identity nicht gefunden: $CODESIGN_IDENTITY" >&2
        exit 1
    else
        echo "WARNUNG: Codesign-Identity nicht sichtbar. DMG bleibt unsigniert."
    fi
fi

if [[ "$NOTARIZE" == "1" ]]; then
    echo "=== Notarizing DMG ==="
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "ABBRUCH: Notary-Keychain-Profil nicht gefunden oder nicht nutzbar: $NOTARY_PROFILE" >&2
        echo "Einmal interaktiv anlegen:" >&2
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$FINAL_DMG"
    xcrun stapler validate "$FINAL_DMG"
fi

echo "=== DMG build successful: $FINAL_DMG ==="
