#!/bin/bash
set -e

cd "$(dirname "$0")"
source .env
export DEEPGRAM_API_KEY

cd Banti
xcodebuild -project Banti.xcodeproj -scheme Banti -destination 'platform=macOS,arch=arm64' -configuration Debug build -quiet

# Clear saved window state so SwiftUI always opens a fresh window
rm -rf ~/Library/Saved\ Application\ State/com.banti.Banti.savedState 2>/dev/null || true

APP=$(echo "$HOME"/Library/Developer/Xcode/DerivedData/Banti-*/Build/Products/Debug/Banti.app/Contents/MacOS/Banti)

if [ ! -f "$APP" ]; then
  echo "Build succeeded, but Banti binary not found."
  exit 1
fi

echo "Starting Banti (foreground, Ctrl-C to stop)..."
echo "---"

# Run binary directly so logs stream to terminal
exec "$APP"
