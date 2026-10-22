#!/bin/bash
# Builds NirTab.app.
#   ./build.sh            local: build, install to /Applications, (re)start. Grants survive (same id + same cert + same path).
#   ./build.sh --release  CI: universal build + NirTab-<version>.zip, no install, no local paths baked in.
# VERSION comes from $VERSION (CI sets it from the git tag), else the default below.
set -euo pipefail
cd "$(dirname "$0")"
RELEASE=0; [ "${1:-}" = "--release" ] && RELEASE=1
APP=NirTab.app
VERSION=${VERSION:-0.14}
BUILD=$(date +%Y%m%d.%H%M)
ID="NirTab Signing"   # self-signed code-signing cert; see README "Signing"
MIN=14.0              # ScreenCaptureKit screenshots need macOS 14

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ $RELEASE = 1 ]; then
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos$MIN main.swift extras.swift rectangle.swift -o "/tmp/NirTab-$arch"
  done
  lipo -create /tmp/NirTab-arm64 /tmp/NirTab-x86_64 -output "$APP/Contents/MacOS/NirTab"
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$MIN" main.swift extras.swift rectangle.swift -o "$APP/Contents/MacOS/NirTab"  # fails → old app keeps running
fi
cp icons/AppIcon.icns "$APP/Contents/Resources/"
SOURCE_KEY=""
[ $RELEASE = 0 ] && SOURCE_KEY="<key>NirTabSourceDir</key><string>$(pwd)</string>"  # local builds only: enables "rebuild from source"
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.nir.nirtab</string>
  <key>CFBundleName</key><string>NirTab</string>
  <key>CFBundleExecutable</key><string>NirTab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>nirtab</string></array></dict></array>
  $SOURCE_KEY
</dict></plist>
EOF

# A stable signing identity is what keeps Accessibility / Screen Recording grants across updates.
if security find-identity -p codesigning | grep -q "\"$ID\""; then
  codesign --force --sign "$ID" "$APP"
else
  echo "warning: '$ID' cert not found, signing ad-hoc — permissions will reset on every update" >&2
  codesign --force --sign - "$APP"
  [ $RELEASE = 0 ] && { tccutil reset Accessibility com.nir.nirtab >/dev/null 2>&1 || true; }  # stale grant would silently block the tap
fi

if [ $RELEASE = 1 ]; then
  ditto -c -k --norsrc --keepParent "$APP" "NirTab-$VERSION.zip"
  echo "built NirTab-$VERSION.zip"
  exit 0
fi

touch "$APP"  # make Finder/Dock pick up the new icon
# Install to /Applications: stable path for Launch at Login and for keeping grants.
pkill -x NirTab 2>/dev/null || true
rm -rf /Applications/NirTab.app
ditto "$APP" /Applications/NirTab.app
# Launch Services can reject the first open right after a replace (-600); retry instead of leaving NirTab down.
for i in 1 2 3 4 5; do
  open /Applications/NirTab.app 2>/dev/null && sleep 1 && pgrep -x NirTab >/dev/null && break
  sleep 1
done
pgrep -x NirTab >/dev/null || { echo "installed but failed to start NirTab" >&2; exit 1; }
echo "installed + started /Applications/NirTab.app $VERSION ($BUILD)"
