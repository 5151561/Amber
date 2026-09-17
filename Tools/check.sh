#!/bin/zsh

# 本地一键体检：构建 → 数警告 → 跑全量测试。审查单 §3-3 抱怨的是「1,155 个测试只能手工跑」，
# 治它不需要远端 CI——这个仓库连 git remote 都没有，写 .github/workflows 只是摆设，
# 而且测试要 Xcode-beta、要真实偏好、要真实资料库，托管 runner 本来也跑不了。
#
# 用法：
#   ./Tools/check.sh            增量构建 + 测试（快，警告数会低估）
#   ./Tools/check.sh --clean    先 clean 再全量构建（警告基线以这一档为准）
#   ./Tools/check.sh --build    只构建不跑测试
#
# ⚠️ 跑测试有真实副作用，不是纯读：
#   - 测试宿主就是 Amber 本身，写死 `UserDefaults.standard` 的设置会被改掉；
#   - 会把 App 的启动任务对**真实资料库**执行一遍（回填会改真文件）。
#   测试期数据可随意改是本项目定好的，但别在「正要拿资料库演示」的时候跑。

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir"

# 缺了它 xcodebuild 报 requires Xcode；指到 /tmp 之类的地方产物会躲开 run.sh 的清扫。
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
derived=build/DerivedData

# 全量构建时的警告条数基线。改动它要在提交信息里写明「哪条没了 / 哪条新增、为什么」——
# 基线的价值全在「有人动它时必须解释一句」，悄悄跟着涨就等于没有。
#
# 口径就是下面那条 `grep | sort -u`（按 file:line:col 去重的唯一条数）。审查单 §8 记的
# 「14 条」不是这个口径——两个子代理各自独立在 84d5d99 上量到 21，去掉 deprecated 与
# 「'as' test is always true」两类正好 14，所以当时多半是分类计的。要对账先对口径。
#
# 2026-09-17：21 → 17。批 J 消掉 1 条（未使用的 seedSongMid）、批 K 消掉 3 条
#（三处 `try? AmberDatabaseMigration.runIfNeeded` 补 `_ =`——`@discardableResult`
# 穿不过 `try?`）。两批都没有新增。
warning_baseline=17

mode=full
case ${1:-} in
    --clean) mode=clean ;;
    --build) mode=build ;;
    "")      ;;
    *)       print -u2 "用法：$0 [--clean|--build]"; exit 1 ;;
esac

common=(-project Amber.xcodeproj -scheme Amber -derivedDataPath "$derived")
log=$(mktemp -t amber-check)
trap 'rm -f "$log"' EXIT

if [[ $mode == clean ]]; then
    print "▸ clean"
    xcodebuild clean "${common[@]}" -quiet >/dev/null
fi

# `|| true` 不是偷懒：开了 pipefail，`grep` 一条都没匹配到（干净构建）就会让整条管道
# 返回 1，`set -e` 当场把脚本杀掉——失败与「没有警告」正好被混成一件事。
# 构建到底成没成，下面读日志判。
print "▸ 构建"
xcodebuild build "${common[@]}" 2>&1 | tee "$log" | grep -E '^(/.*(error|warning):|\*\* BUILD)' || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
    print -u2 "✗ 构建失败"
    exit 1
fi

# 同一条警告会被每个编译它的 target 各报一次，按「文件:行:列 + 正文」去重才是真实条数。
warnings=$(grep -E '^/.*: warning: ' "$log" | sort -u | wc -l | tr -d ' ' || true)
warnings=${warnings:-0}
print "▸ 警告 $warnings 条（基线 $warning_baseline）"
if [[ $mode != clean ]]; then
    print "  注：增量构建只重编改过的文件，这个数会低估。基线核对要跑 --clean。"
elif (( warnings > warning_baseline )); then
    print -u2 "✗ 警告比基线多 $(( warnings - warning_baseline )) 条"
    grep -E '^/.*: warning: ' "$log" | sort -u
    exit 1
elif (( warnings < warning_baseline )); then
    print "  比基线少 $(( warning_baseline - warnings )) 条——顺手把脚本里的基线调下来。"
fi

[[ $mode == build ]] && exit 0

# 串行跑：两份 xcodebuild test 同时在跑会互相杀宿主，日志长得像自己代码崩了。
print "▸ 测试（会动真实偏好与真实资料库）"
xcodebuild test "${common[@]}" 2>&1 | tee "$log" | grep -E '(Test Case.*failed|Executed [0-9]+ test|\*\* TEST)' || true
if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
    print -u2 "✗ 测试失败"
    grep -E "error:|failed" "$log" | sort -u | head -40 || true
    exit 1
fi

grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ failures?[^.]*' "$log" | tail -1 || true
print "✓ 全绿。产物留在 $derived —— 下次跑 ./Tools/run.sh 会顺手把它从 LaunchServices 里清掉。"
