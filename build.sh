#!/bin/zsh
# Baut Ablage.app ohne Xcode, nur mit den Command Line Tools.
set -euo pipefail
cd "${0:A:h}"

# Ab dem macOS-27-SDK ist @State ein Macro, dessen Plugin nur mit Xcode ausgeliefert wird.
# Solange kein Xcode installiert ist, gegen das neueste SDK davor bauen.
if ! xcode-select -p | grep -q Xcode.app; then
  sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$sdk" ]] && export SDKROOT="$sdk"
fi

swift build -c release
bin=$(swift build -c release --show-bin-path)/Ablage

app=build/Ablage.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Ablage"

version=${VERSION:-0.1.0}
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ablage</string>
  <key>CFBundleDisplayName</key><string>Ablage</string>
  <key>CFBundleIdentifier</key><string>de.max-venz.ablage</string>
  <key>CFBundleExecutable</key><string>Ablage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/"
fi

# Ad-hoc-Signatur, damit Schlüsselbund und WebKit sauber mit der App arbeiten.
codesign --force --deep --sign - "$app"
echo "Fertig: $PWD/$app"
