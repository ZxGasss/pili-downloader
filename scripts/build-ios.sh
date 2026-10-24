#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ios_mode="${1:-check}"
case "$ios_mode" in check|archive|export) ;; *) printf '用法：build-ios.sh check|archive|export\n' >&2; exit 64 ;; esac
ios_xcode_app="${BANANA_XCODE_APP:-/Applications/Xcode.app}"
export DEVELOPER_DIR="$ios_xcode_app/Contents/Developer"
ios_builder="$DEVELOPER_DIR/usr/bin/xcodebuild"
if [ ! -x "$ios_builder" ]; then
    printf 'IPA_BLOCKED: 需要当前系统兼容的官方完整Xcode；商店最新版不兼容当前macOS。\n' >&2
    exit 2
fi
run_xcode() {
    python3 - "$ios_builder" "$@" <<'PY'
import subprocess,sys
try:
    raise SystemExit(subprocess.run(sys.argv[1:], timeout=1800).returncode)
except subprocess.TimeoutExpired:
    print('IOS_TIMEOUT: 本次构建超过30分钟，未报告成功。', file=sys.stderr)
    raise SystemExit(124)
PY
}
if ! run_xcode -version; then
    printf 'IPA_BLOCKED: Xcode尚不能启动；请检查上方首次许可或系统错误。\n' >&2
    exit 4
fi
if ! run_xcode -checkFirstLaunchStatus; then
    printf 'IPA_BLOCKED: 请本人完成Xcode首次设置和许可；脚本不会代为接受协议。\n' >&2
    exit 4
fi
if ! run_xcode -showsdks | /usr/bin/grep -q 'iphoneos'; then
    printf 'IPA_BLOCKED: 所选Xcode尚未安装iOS平台SDK。\n' >&2
    exit 5
fi
ios_project=platforms/ios/Banana.xcodeproj
if [ ! -f "$ios_project/project.pbxproj" ]; then
    python3 scripts/prepare-ios-project.py
fi
ios_archive="${BANANA_IOS_ARCHIVE:-$PWD/work/ios/Banana.xcarchive}"
if [ "$ios_mode" = check ]; then
    run_xcode -project "$ios_project" -target Banana -configuration Release -sdk iphoneos "SYMROOT=$PWD/work/ios/DeviceBuild" CODE_SIGNING_ALLOWED=NO build
    printf 'IOS_SDK_BUILD_OK: 已通过真实iOS SDK编译；此模式不生成可安装IPA。\n'
    exit 0
fi
if [ -z "${BANANA_APPLE_TEAM:-}" ]; then
    printf 'IPA_BLOCKED: 需要有效Apple开发团队及设备/分发签名配置；不会生成无法安装的假IPA。\n' >&2
    exit 3
fi
if [ "$ios_mode" = export ]; then
    if [ ! -d "$ios_archive/Products/Applications/Banana.app" ] || [ ! -f "${BANANA_EXPORT_OPTIONS:-}" ]; then
        printf 'IPA_BLOCKED: 需要已签名归档及匹配团队/分发方式的ExportOptions.plist。\n' >&2
        exit 6
    fi
    python3 scripts/verify-ios.py "$ios_archive"
    plutil -lint "$BANANA_EXPORT_OPTIONS"
    ios_export="${BANANA_IPA_OUTPUT:-$PWD/outputs/iOS签名导出}"
    if [ -e "$ios_export" ]; then
        printf 'IPA_BLOCKED: 导出目录已存在，请指定新的BANANA_IPA_OUTPUT以保留旧成品。\n' >&2
        exit 7
    fi
    run_xcode -exportArchive -archivePath "$ios_archive" -exportOptionsPlist "$BANANA_EXPORT_OPTIONS" -exportPath "$ios_export"
    ios_ipa_count=0
    for ios_ipa in "$ios_export"/*.ipa; do
        [ -f "$ios_ipa" ] || continue
        python3 scripts/verify-ios.py "$ios_ipa" --report "$ios_ipa.verification.json"
        ios_ipa_count=$((ios_ipa_count + 1))
    done
    [ "$ios_ipa_count" -eq 1 ] || { printf 'IPA_BLOCKED: 未找到唯一有效IPA。\n' >&2; exit 8; }
    printf 'IOS_EXPORT_FINISHED: 请核验导出IPA签名、授权设备及真机安装后再交付。\n'
    exit 0
fi
if [ -e "$ios_archive" ]; then
    printf 'IPA_BLOCKED: 归档已存在，请指定新的BANANA_IOS_ARCHIVE以保留旧归档。\n' >&2
    exit 7
fi
run_xcode -project "$ios_project" -scheme Banana -configuration Release -destination 'generic/platform=iOS' -archivePath "$ios_archive" -derivedDataPath "$PWD/work/ios/DerivedData" DEVELOPMENT_TEAM="$BANANA_APPLE_TEAM" archive
printf 'IOS_ARCHIVE_OK: 导出IPA仍需与证书及目标设备匹配的ExportOptions配置。\n'
