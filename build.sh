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

# Signieren mit einer eigenen, stabilen Identität. Bei einer Ad-hoc-Signatur ändert sich der
# Code-Hash mit jedem Build, und der Schlüsselbund fragt dann jedes Mal neu nach dem Passwort.
# Zertifikat und Schlüssel liegen in einem eigenen Schlüsselbund unter .signing/, der
# Login-Schlüsselbund bleibt unberührt.
signing="$PWD/.signing"
kc="$signing/ablage.keychain-db"
identity="Ablage Local Signing"
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
  # security kann das moderne PKCS12-Format von OpenSSL 3 nicht lesen, daher die Legacy-Algorithmen.
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$identity" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$tmp/id.p12" -passout "pass:$pw"
  # create-keychain kann den neuen Schlüsselbund in die Suchliste hängen; die bleibt unverändert.
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
codesign --force --deep --keychain "$kc" --sign "$identity" "$app"
echo "Fertig: $PWD/$app"
