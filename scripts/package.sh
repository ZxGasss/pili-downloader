#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
name=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Info.plist)
root="work/dmg-root-$version"
mkdir -p "$root"
dmg="outputs/$name-$version-AppleSilicon.dmg"
if [ -e "$dmg" ]; then dmg="outputs/$name-$version-AppleSilicon-b$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist).dmg"; fi
ditto "outputs/$name-$version/$name.app" "$root/$name.app"
if [ ! -L "$root/Applications" ]; then ln -s /Applications "$root/Applications"; fi
cp README.md "$root/安装与使用说明.md"
test ! -e "$dmg"
hdiutil create -volname "$name" -srcfolder "$root" -format UDZO "$dmg"
hdiutil verify "$dmg"
printf 'DMG_OK\n'
