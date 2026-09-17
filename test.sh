#!/bin/zsh
# Führt die Tests ohne Xcode aus. Die Command Line Tools finden das Macro-Plugin von
# Swift Testing nicht von selbst, deshalb der Pfad.
set -euo pipefail
cd "${0:A:h}"
# Wie in build.sh: ein macOS-26-SDK wählen, falls das voreingestellte nicht passt.
sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
if [[ "${sdk_major:-0}" != 26 ]]; then
  sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$sdk" ]] && export SDKROOT="$sdk"
fi
# Ohne Xcode finden die Command Line Tools das Macro-Plugin von Swift Testing nicht von selbst.
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$plugins" ]]; then
  extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
python3 scripts/make-strings.py
swift test ${extra[@]:-} "$@"
