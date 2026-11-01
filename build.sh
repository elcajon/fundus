#!/bin/zsh
# Builds Fundus.app without Xcode, with just the Command Line Tools.
set -euo pipefail
cd "${0:A:h}"

# Needs a macOS 26 SDK: in the 27 SDK @State is a macro whose plugin ships only with Xcode;
# older SDKs don't know the Liquid Glass APIs. If the selected SDK doesn't fit, fall back
# to a 26 SDK from the Command Line Tools.
sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
if [[ "${sdk_major:-0}" != 26 ]]; then
  sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$sdk" ]] && export SDKROOT="$sdk"
fi

# Check translations: fails if a new string has no English version.
python3 scripts/make-strings.py

swift build -c release
bin=$(swift build -c release --show-bin-path)/Fundus

app=build/Fundus.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Fundus"

# SwiftPM writes the minimum version (15.0) as the SDK version. macOS uses it to decide whether
# the app gets the current design (Liquid Glass), so fill in the real SDK version.
sdk_version=$(xcrun --sdk "${SDKROOT:-macosx}" --show-sdk-version)
vtool -set-build-version macos 15.0 "$sdk_version" -replace \
  -output "$app/Contents/MacOS/Fundus" "$app/Contents/MacOS/Fundus"

version=${VERSION:-0.1.0}
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Fundus</string>
  <key>CFBundleDisplayName</key><string>Fundus</string>
  <!-- The identifier stays: keychain access, settings and the login item depend on it. -->
  <key>CFBundleIdentifier</key><string>de.max-venz.ablage</string>
  <key>CFBundleExecutable</key><string>Fundus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key>
  <array><string>de</string><string>en</string></array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>de.max-venz.ablage.document</string>
      <key>CFBundleURLSchemes</key><array><string>ablage</string><string>fundus</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>Max Venz</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Login item: starts Fundus silently at login (without a window).
launcher="$app/Contents/Library/LoginItems/FundusLauncher.app"
mkdir -p "$launcher/Contents/MacOS"
swiftc -O -sdk "${SDKROOT:-$(xcrun --show-sdk-path)}" -target "$(uname -m)-apple-macos15.0" \
  Launcher/main.swift -o "$launcher/Contents/MacOS/FundusLauncher"
vtool -set-build-version macos 15.0 "$sdk_version" -replace \
  -output "$launcher/Contents/MacOS/FundusLauncher" "$launcher/Contents/MacOS/FundusLauncher"
cat > "$launcher/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FundusLauncher</string>
  <key>CFBundleDisplayName</key><string>Fundus</string>
  <key>CFBundleIdentifier</key><string>de.max-venz.ablage.launcher</string>
  <key>CFBundleExecutable</key><string>FundusLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PLIST

# Render the icons (light and dark) and the menu bar icon fresh.
icons=.build/icons
rm -rf "$icons" && mkdir -p "$icons"
swift scripts/make-icon.swift "$icons"
iconutil -c icns "$icons/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
iconutil -c icns "$icons/AppIconDark.iconset" -o "$app/Contents/Resources/AppIconDark.icns"
cp "$icons/MenuBarIcon.png" "$icons/MenuBarIcon@2x.png" "$app/Contents/Resources/"
cp -R Resources/*.lproj "$app/Contents/Resources/"

# Sign with our own, stable identity. With an ad-hoc signature the code hash changes
# with every build, and the keychain then asks for the password again each time.
# Certificate and key live in a separate keychain under .signing/; the login
# keychain is left alone.
signing="$PWD/.signing"
kc="$signing/ablage.keychain-db"
# Name of the local identity: stays the same so existing keychain access grants keep working.
identity="${SIGN_IDENTITY:-Ablage Local Signing}"
# A CI runner has no keychain and no persistent identity: sign ad hoc.
if [[ "$identity" == "-" ]]; then
  codesign --force --options runtime --sign - "$launcher"
  codesign --force --options runtime --sign - "$app"
  echo "Fertig (ad hoc signiert): $PWD/$app"
  exit 0
fi

if [[ ! -f "$kc" ]]; then
  mkdir -p "$signing" && chmod 700 "$signing"
  openssl rand -hex 24 > "$signing/password" && chmod 600 "$signing/password"
  pw=$(<"$signing/password")
  tmp=$(mktemp -d)
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  # security can't read OpenSSL 3's modern PKCS12 format, hence the legacy algorithms.
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$identity" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$tmp/id.p12" -passout "pass:$pw"
  # create-keychain may add the new keychain to the search list; keep that list unchanged.
  saved=("${(@f)$(security list-keychains -d user | tr -d '" ')}")
  security create-keychain -p "$pw" "$kc"
  security list-keychains -d user -s "${saved[@]}"
  security set-keychain-settings "$kc"
  security unlock-keychain -p "$pw" "$kc"
  security import "$tmp/id.p12" -k "$kc" -P "$pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$kc" >/dev/null
  rm -rf "$tmp"
fi
security unlock-keychain -p "$(<"$signing/password")" "$kc"
# Hardened runtime: no injected foreign code, no debugger attaching from outside.
# Newer macOS versions treat a self-signed certificate as untrusted (CSSMERR_TP_NOT_TRUSTED),
# and codesign can no longer find it then. In that case sign ad hoc.
if codesign --force --options runtime --keychain "$kc" --sign "$identity" "$launcher" 2>/dev/null; then
  codesign --force --options runtime --keychain "$kc" --sign "$identity" "$app"
  echo "Fertig: $PWD/$app"
else
  echo "Warnung: Identität „$identity“ nicht nutzbar, signiere ad hoc (der Schlüsselbund fragt nach jedem Build neu)." >&2
  codesign --force --options runtime --sign - "$launcher"
  codesign --force --options runtime --sign - "$app"
  echo "Fertig (ad hoc signiert): $PWD/$app"
fi
