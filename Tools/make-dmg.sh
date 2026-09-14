#!/bin/zsh

# 打分发用的 dmg：Release 构建 → 校验签名 → 压成带 /Applications 快捷方式的磁盘映像。
# 和 run.sh 各管一头：run.sh 管「本机跑最新版」，这个脚本只产出 build/dist 里的 dmg，
# 不动 /Applications/Amber.app，也不启动任何东西。

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
derived_data="$project_dir/build/DerivedDataDist"
configuration=${1:-Release}
product="$derived_data/Build/Products/$configuration/Amber.app"
dist_dir="$project_dir/build/dist"
# 签名校验用的 Team ID。两条来源都不入库：
#   - 环境变量 AMBER_TEAM_ID（优先）
#   - Support/Signing.local.xcconfig 里的 AMBER_DEVELOPMENT_TEAM（Xcode 里 ⌘R 也读这份）
expected_team="${AMBER_TEAM_ID:-}"
if [[ -z $expected_team && -f "$project_dir/Support/Signing.local.xcconfig" ]]; then
    expected_team=$(sed -n 's/^[[:space:]]*AMBER_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' \
        "$project_dir/Support/Signing.local.xcconfig" | tr -d '[:space:]' | head -1)
fi
if [[ -z $expected_team || $expected_team == XXXXXXXXXX ]]; then
    print -u2 "没有配置签名用的 Team ID。二选一："
    print -u2 "  export AMBER_TEAM_ID=XXXXXXXXXX"
    print -u2 "  或把 Support/Signing.local.xcconfig.example 复制成 Signing.local.xcconfig 并填上"
    exit 1
fi

if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
    print -u2 "用法：$0 [Release|Debug]"
    exit 1
fi

if [[ -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

cd "$project_dir"

build_commit=$(git rev-parse --short HEAD 2>/dev/null || print unknown)
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    build_commit="$build_commit+dirty"
fi
build_date=$(date '+%Y-%m-%d %H:%M:%S')

xcodebuild \
    -project Amber.xcodeproj \
    -scheme Amber \
    -configuration "$configuration" \
    -derivedDataPath "$derived_data" \
    AMBER_DEVELOPMENT_TEAM="$expected_team" \
    AMBER_BUILD_COMMIT="$build_commit" \
    AMBER_BUILD_DATE="$build_date" \
    CURRENT_PROJECT_VERSION="$(date '+%Y%m%d.%H%M')" \
    build

# 和 build-install-signed.sh 同一套底线：ad-hoc 或换了 team 的产物不许进 dmg。
signature_info=$(codesign -dvvv --requirements - "$product" 2>&1)
if [[ "$signature_info" == *"Signature=adhoc"* ]]; then
    print -u2 "拒绝打包：构建产物是 ad-hoc 签名。"
    exit 1
fi
if [[ "$signature_info" != *"TeamIdentifier=$expected_team"* ]]; then
    print -u2 "拒绝打包：TeamIdentifier 不是 $expected_team。"
    exit 1
fi
codesign --verify --deep --verbose=4 "$product"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$product/Contents/Info.plist")
# Debug 和 Release 在同一个 commit 上不能撞名，否则后跑的那次会覆盖前一份。
suffix=""
[[ "$configuration" == Debug ]] && suffix="-debug"
dmg="$dist_dir/Amber-$version-$build_commit$suffix.dmg"
volume_name="Amber $version"

# 暂存目录就是 dmg 的根：Amber.app + 拖进去用的 /Applications 快捷方式。
staging=$(mktemp -d /tmp/am-dmg.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto "$product" "$staging/Amber.app"
ln -s /Applications "$staging/Applications"

mkdir -p "$dist_dir"
rm -f "$dmg"
hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "$dmg"

# xcodebuild 会把产物注册进 LaunchServices，留着就多一份同 bundle id 的 Amber.app。
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -u "$product" 2>/dev/null || true
rm -rf "$product"

print
print "已生成：$dmg"
print "大小：  $(du -h "$dmg" | cut -f1)"
print "构建：  $configuration  $build_commit  $build_date"
