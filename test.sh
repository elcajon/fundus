#!/bin/zsh
# Runs the tests without Xcode. The Command Line Tools don't find the macro plugin of
# Swift Testing on their own, hence the path.
set -euo pipefail
cd "${0:A:h}"
# As in build.sh: pick a macOS 26 SDK if the default one doesn't fit.
sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
if [[ "${sdk_major:-0}" != 26 ]]; then
  sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$sdk" ]] && export SDKROOT="$sdk"
fi
# Without Xcode, the Command Line Tools don't find the macro plugin of Swift Testing on their own.
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$plugins" ]]; then
  extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
python3 scripts/make-strings.py
swift test ${extra[@]:-} "$@"
