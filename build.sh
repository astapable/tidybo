#!/bin/zsh
# Builds Tidybo.app, signs it with a stable identity and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Tidybo.app
BUNDLE_ID=app.tidybo.Tidybo
# Log outside the project: ~/Documents and ~/Desktop are privacy-protected, and macOS refuses to
# launch an app whose output is redirected there.
LOG="$HOME/Library/Logs/Tidybo/run.log"

# Stable identity keeps the Accessibility grant across rebuilds.
# Falls back to ad-hoc (grant may need re-approval after each build).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')
IDENTITY=${IDENTITY:--}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# App icon (the robot head), regenerated only when its script changes.
if [[ ! -f build/AppIcon.icns || Tools/make_icon.swift -nt build/AppIcon.icns ]]; then
    swift Tools/make_icon.swift build >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit -framework ApplicationServices -framework QuickLookThumbnailing \
    Sources/*.swift -o "$APP/Contents/MacOS/Tidybo"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime "$APP"
echo "Signed with: $IDENTITY"

# Make Finder/LaunchServices pick up the current icon instead of a cached placeholder.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

[[ "${1:-}" == "--no-run" ]] && exit 0

pkill -x Tidybo 2>/dev/null || true
while pgrep -x Tidybo >/dev/null; do sleep 0.1; done
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
# Launch via LaunchServices so the app (not the terminal) is the TCC-responsible process.
# LaunchServices may still be tearing down the old instance (error -600): retry briefly.
for i in 1 2 3 4 5; do
    sleep 0.4
    if open --stdout "$LOG" --stderr "$LOG" "$APP" 2>/dev/null; then
        echo "Launched. Log: $LOG  (tail -f it)"
        exit 0
    fi
done
echo "Could not launch $APP (see: open \"$APP\")" >&2
exit 1
