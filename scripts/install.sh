#!/bin/sh
# Builds a release Amyrlin.app and installs it in /Applications, replacing the one there, then reopens it.
#   sh scripts/install.sh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Amyrlin.xcodeproj -scheme Amyrlin -configuration Release -derivedDataPath build/DerivedData build | grep -E "error:|BUILD"
osascript -e 'quit app "Amyrlin"' 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Amyrlin >/dev/null || break; sleep 1; done
rm -rf /Applications/Amyrlin.app
ditto build/DerivedData/Build/Products/Release/Amyrlin.app /Applications/Amyrlin.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Amyrlin.app
open /Applications/Amyrlin.app
echo "installed /Applications/Amyrlin.app"
