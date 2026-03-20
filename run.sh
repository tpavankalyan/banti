#!/bin/bash
set -e

cd "$(dirname "$0")"
source .env
export DEEPGRAM_API_KEY

cd Banti
xcodebuild -project Banti.xcodeproj -scheme Banti -destination 'platform=macOS,arch=arm64' -configuration Debug build -quiet

pkill -x Banti 2>/dev/null && sleep 0.5 || true
rm -rf ~/Library/Saved\ Application\ State/com.banti.Banti.savedState 2>/dev/null || true

APP=$(echo "$HOME"/Library/Developer/Xcode/DerivedData/Banti-*/Build/Products/Debug/Banti.app/Contents/MacOS/Banti)

if [ ! -f "$APP" ]; then
  echo "Build succeeded, but Banti binary not found."
  exit 1
fi

# Run the binary directly (not via `open`) so it gets env vars and works reliably
"$APP" &
echo "Banti running (pid $!)"
