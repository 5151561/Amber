#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
derived_data="$project_dir/build/DerivedData"
destination="${1:-/Applications/Amber.app}"
configuration="${2:-Debug}"
product="$derived_data/Build/Products/$configuration/Amber.app"
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

if [[ -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

cd "$project_dir"

# 不传 CODE_SIGNING_ALLOWED=NO，也不在构建后执行 `codesign -`。
# Xcode 会使用工程中的 Apple Development 身份和 DEVELOPMENT_TEAM。
build_commit=$(git rev-parse --short HEAD 2>/dev/null || print unknown)
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    build_commit="$build_commit+dirty"
fi
build_date=$(date '+%Y-%m-%d %H:%M:%S')

# CFBundleVersion 只能是数字和点，用时间戳；commit 放自定义键 AmberBuildCommit。
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

signature_info=$(codesign -dvvv --requirements - "$product" 2>&1)

if [[ "$signature_info" == *"Signature=adhoc"* ]]; then
    print -u2 "拒绝安装：构建产物是 ad-hoc 签名。"
    exit 1
fi

if [[ "$signature_info" != *"TeamIdentifier=$expected_team"* ]]; then
    print -u2 "拒绝安装：TeamIdentifier 不是 $expected_team。"
    exit 1
fi

if [[ "$signature_info" != *'identifier "com.changlepan.Amber" and anchor apple generic'* ]]; then
    print -u2 "拒绝安装：Designated Requirement 不符合 Amber 的长期签名身份。"
    exit 1
fi

codesign --verify --deep --verbose=4 "$product"

# 先删旧 bundle 再 ditto：ditto 是合并复制，留着会残留上一版删掉的文件。
rm -rf "$destination"
ditto "$product" "$destination"
codesign --verify --deep --verbose=4 "$destination"

print "已安装长期签名版本：$destination"
print "TeamIdentifier: $expected_team"
print "构建：$configuration  $build_commit  $build_date"

