#!/bin/sh
# Builds build/MyCMS-<version>.dmg from a Release archive signed with your development identity.
# For this Mac only: nothing is notarised, so a downloaded copy is blocked by Gatekeeper.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build"
archive="$build/MyCMS.xcarchive"
staging=""
partial=""

fail() {
    echo "make-dmg: $1" >&2
    exit 1
}

# Nothing half made survives a failure: no staging folder, no partial disk image.
cleanup() {
    [ -n "$staging" ] && rm -rf "$staging"
    [ -n "$partial" ] && rm -f "$partial"
    return 0
}
trap cleanup EXIT INT TERM

config="$root/Config/Local.xcconfig"
[ -f "$config" ] || fail "Config/Local.xcconfig is missing. Copy Config/Local.xcconfig.example and put your Team ID in it."
team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$config" | tail -n 1)"
# A Team ID is ten capital letters or digits; the example file's placeholder is not one.
printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$' || fail "Config/Local.xcconfig has no Team ID. Set DEVELOPMENT_TEAM to yours."

mkdir -p "$build"
rm -rf "$archive"
echo "make-dmg: archiving MyCMS in Release"
xcodebuild -project "$root/MyCMS.xcodeproj" -scheme MyCMS -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" -quiet \
    archive DEVELOPMENT_TEAM="$team" || fail "xcodebuild could not archive the app. Its own messages are above."

app="$archive/Products/Applications/MyCMS.app"
[ -d "$app" ] || fail "The archive holds no MyCMS.app."

for file in LICENSE.md grammar.v1.md rewrite.v1.md; do
    [ -f "$app/Contents/Resources/$file" ] || fail "The app is missing Contents/Resources/$file, so no disk image was made."
done

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" \
    || fail "Could not read the app's version."

staging="$(mktemp -d "${TMPDIR:-/tmp}/mycms-dmg.XXXXXX")"
ditto "$app" "$staging/MyCMS.app"
ln -s /Applications "$staging/Applications"

dmg="$build/MyCMS-$version.dmg"
partial="$build/.MyCMS-$version.partial.dmg"
rm -f "$partial"
hdiutil create -quiet -volname "MyCMS" -srcfolder "$staging" -format UDZO -ov "$partial" \
    || fail "hdiutil could not make the disk image."
mv -f "$partial" "$dmg"
partial=""

echo "make-dmg: $dmg"
