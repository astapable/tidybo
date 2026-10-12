#!/bin/zsh
# Builds a distributable Tidybo.zip:
#  - universal binary (Apple Silicon + Intel), optimized, symbols stripped
#  - source paths remapped so no local folders / user name end up in the binary
#  - ad-hoc signature (no personal certificate, name or e-mail inside)
#  - privacy check: fails if anything personal is found
# Output: dist/Tidybo-<version>.zip and its SHA-256.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Info.plist)
OUT=dist
APP=$OUT/Tidybo.app
ZIP=$OUT/Tidybo-$VERSION.zip
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || Tools/make_icon.swift -nt build/AppIcon.icns ]]; then
    mkdir -p build
    swift Tools/make_icon.swift build >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Compile per architecture with source paths mapped to "." so #file strings carry no local paths.
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" \
        -gnone -file-prefix-map "$PWD=." \
        -framework AppKit -framework ApplicationServices -framework QuickLookThumbnailing \
        Sources/*.swift -o "$TMP/Tidybo-$ARCH"
done
lipo -create "$TMP/Tidybo-arm64" "$TMP/Tidybo-x86_64" -output "$APP/Contents/MacOS/Tidybo"
strip -x "$APP/Contents/MacOS/Tidybo"

# Ad-hoc signature: valid on every Mac, carries no identity.
codesign --force --sign - --identifier "$BUNDLE_ID" --options runtime "$APP"

# Privacy check: nothing that points to the author's machine or accounts. The personal strings
# are collected from this Mac at build time (user, full name, home, git and certificate e-mails),
# so none of them is written in this script.
PERSONAL=("$USER" "$HOME" $(id -F 2>/dev/null))
PERSONAL+=($(git config --global user.email 2>/dev/null) $(git config user.email 2>/dev/null))
PERSONAL+=($(security find-identity -v -p codesigning 2>/dev/null | grep -oE '[[:alnum:]._%+-]+@[[:alnum:].-]+'))
PERSONAL+=($(security find-identity -v -p codesigning 2>/dev/null | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()'))
PATTERN=$(printf '%s\n' "${PERSONAL[@]}" "/Users/" "Apple Development" | grep -v '^$' | sed 's/[.[\*^$+?(){}|]/\\&/g' | paste -sd'|' -)
SIG=$(codesign -dvv "$APP" 2>&1)
if strings -a "$APP/Contents/MacOS/Tidybo" | grep -iE "$PATTERN" >/dev/null \
   || grep -q "Authority=" <<< "$SIG" \
   || ! grep -q "Signature=adhoc" <<< "$SIG" \
   || ! grep -q "TeamIdentifier=not set" <<< "$SIG"; then
    echo "PRIVACY CHECK FAILED: personal data found in the build:" >&2
    strings -a "$APP/Contents/MacOS/Tidybo" | grep -iE "$PATTERN" | head >&2 || true
    grep -E "Authority=|TeamIdentifier=|Signature=" <<< "$SIG" >&2 || true
    exit 1
fi
echo "Privacy check passed: ad-hoc signature, no personal strings."

xattr -cr "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
echo "Built $ZIP"
echo "SHA-256: $SHA"
lipo -archs "$APP/Contents/MacOS/Tidybo"
