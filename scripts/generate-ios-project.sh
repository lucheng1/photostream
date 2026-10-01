#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null; then
  echo "Install XcodeGen: brew install xcodegen" >&2
  exit 1
fi

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Full Xcode.app is required to build the iOS client." >&2
  echo "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

xcodegen generate
open PhotoStream.xcodeproj
echo "In Xcode: select your iPhone, Signing team, then Run."
