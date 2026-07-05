#!/bin/bash
set -euo pipefail

echo "=== Building Savage Mod Player App in Release Mode ==="
swift build -c release
APP_VERSION="$(cat VERSION)"

echo "=== Creating macOS App Bundle structure ==="
APP_DIR="Savage Mod Player.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($APPLE_TEAM_ID)}"
SIGN_APP="${SIGN_APP:-auto}"

# Recreate the folders
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy release binary
cp ".build/release/SavageModPlayerApp" "$MACOS_DIR/"

# --- Quick-Look-Extension (Appex) bauen -------------------------------------
# SwiftPM kann keine .appex-Bundles erzeugen, deshalb kompiliert swiftc die
# Extension direkt: Core-Quellen + PreviewProvider werden zu EINEM Modul
# gebaut (darum kein "import SavageModPlayerCore" im Provider).
# Der Einstiegspunkt einer NSExtension ist _NSExtensionMain (statt main).
echo "=== Building Quick Look Extension ==="
QL_NAME="SavageModPlayerQuickLook"
QL_APPEX="$CONTENTS_DIR/PlugIns/$QL_NAME.appex"
QL_MACOS_DIR="$QL_APPEX/Contents/MacOS"
mkdir -p "$QL_MACOS_DIR"

ARCH="$(uname -m)"
swiftc -O -parse-as-library \
    -module-name "$QL_NAME" \
    -target "$ARCH-apple-macos13.0" \
    -application-extension \
    Sources/SavageModPlayerCore/Parser/*.swift \
    Sources/SavageModPlayerCore/DSP/*.swift \
    quicklook/PreviewProvider.swift \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$QL_MACOS_DIR/$QL_NAME"

cat <<EOF > "$QL_APPEX/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Standard-Keys, die Xcode fuer Appexes immer setzt — ExtensionFoundation
         reagiert auf fehlende Werte teils mit NSException (nil-Insert). -->
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>Savage Mod Player Quick Look</string>
    <key>CFBundleExecutable</key>
    <string>$QL_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.viben.SavageModPlayer.QuickLook</string>
    <key>CFBundleName</key>
    <string>$QL_NAME</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLIsDataBasedPreview</key>
            <true/>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>com.viben.savage-modplayer.mod</string>
                <string>com.viben.savage-modplayer.s3m</string>
                <!-- Ist VLC (o.ae.) installiert, gewinnen dessen EXPORTIERTE
                     UTIs gegen unsere importierten — .mod ist dann
                     org.videolan.mod. Diese UTIs zusaetzlich claimen, damit
                     die Preview auch auf solchen Systemen funktioniert. -->
                <string>org.videolan.mod</string>
                <string>org.videolan.s3m</string>
            </array>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$QL_NAME.PreviewProvider</string>
    </dict>
</dict>
</plist>
EOF

# Compile and copy AppIcon.icns if AppIcon.png exists
if [ -f "src/AppIcon.png" ]; then
    echo "=== Compiling AppIcon.icns ==="
    mkdir -p AppIcon.iconset
    sips -s format png -z 16 16     src/AppIcon.png --out AppIcon.iconset/icon_16x16.png
    sips -s format png -z 32 32     src/AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png
    sips -s format png -z 32 32     src/AppIcon.png --out AppIcon.iconset/icon_32x32.png
    sips -s format png -z 64 64     src/AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png
    sips -s format png -z 128 128   src/AppIcon.png --out AppIcon.iconset/icon_128x128.png
    sips -s format png -z 256 256   src/AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png
    sips -s format png -z 256 256   src/AppIcon.png --out AppIcon.iconset/icon_256x256.png
    sips -s format png -z 512 512   src/AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png
    sips -s format png -z 512 512   src/AppIcon.png --out AppIcon.iconset/icon_512x512.png
    sips -s format png -z 1024 1024 src/AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png
    iconutil -c icns AppIcon.iconset
    cp AppIcon.icns "$RESOURCES_DIR/"
    rm -rf AppIcon.iconset AppIcon.icns
fi

# Create Info.plist
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SavageModPlayerApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.viben.SavageModPlayer</string>
    <key>CFBundleName</key>
    <string>Savage Mod Player</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <!-- Erscheint unten im nativen "Über"-Panel -->
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Daniel Müller</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Tracker Module</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.viben.savage-modplayer.mod</string>
                <string>com.viben.savage-modplayer.s3m</string>
            </array>
        </dict>
    </array>
    <!-- UTI-Deklarationen fuer .mod/.s3m: LaunchServices braucht sie, damit
         die Quick-Look-Extension (QLSupportedContentTypes) den Dateitypen
         zugeordnet werden kann. -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.viben.savage-modplayer.mod</string>
            <key>UTTypeDescription</key>
            <string>Amiga Tracker Module</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mod</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.viben.savage-modplayer.s3m</string>
            <key>UTTypeDescription</key>
            <string>ScreamTracker 3 Module</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>s3m</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

QL_ENTITLEMENTS="quicklook/SavageModPlayerQuickLook.entitlements"

if [[ "$SIGN_APP" != "0" ]]; then
    echo "=== Checking code signing identity ==="
    if security find-identity -v -p codesigning | grep -Fq "$CODESIGN_IDENTITY"; then
        echo "=== Signing App Bundle ==="
        # Reihenfolge wichtig: erst die Extension MIT ihren Sandbox-
        # Entitlements, dann die App OHNE --deep. Ein --deep auf der App
        # wuerde den Appex neu signieren und dabei dessen Entitlements
        # verwerfen — Quick Look laedt unsandboxte Extensions nicht.
        # Hardened Runtime ist Pflicht fuer spaetere Notarisierung.
        codesign --force --options runtime --timestamp \
            --entitlements "$QL_ENTITLEMENTS" \
            --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/PlugIns/SavageModPlayerQuickLook.appex"
        codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR"
        codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    elif [[ "$SIGN_APP" == "1" || "${REQUIRE_CODESIGN:-0}" == "1" ]]; then
        echo "ABBRUCH: Codesign-Identity nicht gefunden: $CODESIGN_IDENTITY" >&2
        echo "Tipp: SIGN_APP=0 bash build_app.sh baut lokal ohne Signatur." >&2
        exit 1
    else
        echo "WARNUNG: Codesign-Identity nicht sichtbar. App wird nur ad-hoc signiert."
        echo "Tipp: REQUIRE_CODESIGN=1 bash build_app.sh erzwingt Signatur fuer Releases."
        # Ad-hoc-Signatur reicht lokal, damit Quick Look den sandboxten Appex
        # laedt (ganz unsigniert wird die Extension ignoriert).
        codesign --force --entitlements "$QL_ENTITLEMENTS" --sign - \
            "$APP_DIR/Contents/PlugIns/SavageModPlayerQuickLook.appex"
        codesign --force --sign - "$APP_DIR"
    fi
fi

echo "=== App Bundle Created Successfully: $APP_DIR ==="
echo "You can now double-click '$APP_DIR' in Finder to launch the player!"
