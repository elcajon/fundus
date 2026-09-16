#!/bin/zsh
# Führt die Tests ohne Xcode aus. Die Command Line Tools finden das Macro-Plugin von
# Swift Testing nicht von selbst, deshalb der Pfad.
set -euo pipefail
cd "${0:A:h}"
if ! xcode-select -p | grep -q Xcode.app; then
  sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$sdk" ]] && export SDKROOT="$sdk"
  extra=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)
fi
python3 scripts/make-strings.py
swift test ${extra[@]:-} "$@"
