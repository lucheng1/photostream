#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product PhotoStreamServer -c release
BIN=""
for candidate in \
  "$ROOT/.build/out/Products/Release/PhotoStreamServer" \
  "$ROOT/.build/release/PhotoStreamServer" \
  "$ROOT/.build/arm64-apple-macosx/release/PhotoStreamServer"
do
  if [[ -x "$candidate" ]]; then BIN="$candidate"; break; fi
done
if [[ -z "$BIN" ]]; then
  BIN="$(find "$ROOT/.build" -name PhotoStreamServer -type f -perm -111 ! -path '*.dSYM*' | head -1)"
fi
if [[ -z "${BIN}" || ! -x "$BIN" ]]; then
  echo "Built binary not found" >&2
  exit 1
fi
echo "Using binary: $BIN"
APP="$ROOT/dist/PhotoStream.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoStream"
cp "$ROOT/MacServer/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PhotoStream"

# Ad-hoc sign so TCC Photos prompt can attach to the bundle
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Launching $APP"
open "$APP"
echo "Look for the PS menu bar item. Note the PIN, then connect from the iPhone app."
