#!/usr/bin/env bash
set -euo pipefail

# Hosted runners are disposable; use their formula metadata and skip maintenance.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

missing_tools=()
for tool in xcodegen xcbeautify; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done
if ((${#missing_tools[@]})); then
  brew install "${missing_tools[@]}"
fi

xcodebuild -version
# Building needs SDKs, not downloaded simulator runtimes. Check each job's SDK.
required_sdk="${1:?usage: setup.sh xros|xrsimulator}"
if ! xcrun --sdk "$required_sdk" --show-sdk-path >/dev/null 2>&1; then
  xcodebuild -downloadPlatform visionOS
fi
xcrun --sdk "$required_sdk" --show-sdk-path
xcodegen generate
