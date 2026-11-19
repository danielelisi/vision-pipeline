#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  xros|xrsimulator) sdk="$1" ;;
  *) echo "Usage: $0 {xros|xrsimulator}" >&2; exit 2 ;;
esac

xcodebuild -version
# Generic builds need the SDK, not a booted simulator or downloaded runtime.
if ! xcrun --sdk "$sdk" --show-sdk-path; then
  echo "The selected Xcode must include the $sdk SDK." >&2
  exit 1
fi

# Reuse runner-provided tools, including xcbeautify; install only missing ones.
for tool in xcodegen xcbeautify; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    brew install "$tool"
  fi
done
