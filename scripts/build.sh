#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work outputs
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
name=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Info.plist)
app="outputs/$name-$version/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Tools" "$app/Contents/Resources/Licenses"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx13.0 -O Sources/*.swift -o "$app/Contents/MacOS/PiliDownloader"
strip -x "$app/Contents/MacOS/PiliDownloader"
cp Info.plist "$app/Contents/Info.plist"
cp work/deps/yt-dlp work/deps/ffmpeg work/deps/aria2c "$app/Contents/Resources/Tools/"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx13.0 -O Tools/ThumbnailWorker.swift -o "$app/Contents/Resources/Tools/PiliThumbnail"
codesign --force --sign - "$app/Contents/Resources/Tools/PiliThumbnail"
cp work/licenses/* "$app/Contents/Resources/Licenses/"
cp README.md "$app/Contents/Resources/使用说明.md"
cp ROADMAP.md CONTRIBUTING.md "$app/Contents/Resources/"
if [ -f Assets/TMDB.svg ]; then cp Assets/TMDB.svg "$app/Contents/Resources/"; fi
if [ -f Assets/AppIcon-2.0.icns ]; then cp Assets/AppIcon-2.0.icns "$app/Contents/Resources/AppIcon.icns";
elif [ -f work/AppIcon20.icns ]; then cp work/AppIcon20.icns "$app/Contents/Resources/AppIcon.icns";
elif [ -f work/AppIcon.icns ]; then cp work/AppIcon.icns "$app/Contents/Resources/"; fi
codesign --force --sign - "$app/Contents/Resources/Tools/ffmpeg"
codesign --force --sign - "$app/Contents/Resources/Tools/yt-dlp"
codesign --force --sign - "$app/Contents/Resources/Tools/aria2c"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'APP_BUILD_OK\n'
