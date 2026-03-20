#!/bin/bash
set -e

cd "$(dirname "$0")"
source .env

cd Banti
xcodebuild -project Banti.xcodeproj -scheme Banti -destination 'platform=macOS,arch=arm64' -configuration Debug build -quiet

shopt -s nullglob
apps=( "$HOME"/Library/Developer/Xcode/DerivedData/Banti-*/Build/Products/Debug/Banti.app )
shopt -u nullglob

if [ ${#apps[@]} -eq 0 ]; then
  echo "Build succeeded, but Banti.app was not found in DerivedData."
  exit 1
fi

APP_PATH="${apps[0]}"
open "$APP_PATH"
osascript -e 'tell application "Banti" to activate' >/dev/null 2>&1 || true
echo "Banti launched: $APP_PATH"
