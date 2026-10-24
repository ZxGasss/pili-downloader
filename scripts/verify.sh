#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
swiftc -swift-version 5 -parse-as-library Sources/MemoryBudget.swift Sources/Models.swift Sources/AdvancedOptions.swift Sources/Episodes.swift Sources/EpisodeBatches.swift Sources/ExistingMedia.swift Sources/TaskHistory.swift Sources/DownloadTuning.swift Sources/ProcessHygiene.swift Sources/BiliAPIFallback.swift Sources/Backend.swift Sources/MediaIntegrity.swift Tests/Smoke.swift -o work/smoke-tests
work/smoke-tests
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
name=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Info.plist)
app="outputs/$name-$version/$name.app"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
file "$app/Contents/MacOS/PiliDownloader" "$app/Contents/Resources/Tools/ffmpeg"
"$app/Contents/Resources/Tools/yt-dlp" --version
"$app/Contents/Resources/Tools/ffmpeg" -version | head -n 3
"$app/Contents/Resources/Tools/aria2c" --version | head -n 1
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
if [ -f "outputs/$name-$version-AppleSilicon.dmg" ]; then hdiutil verify "outputs/$name-$version-AppleSilicon.dmg"; fi
