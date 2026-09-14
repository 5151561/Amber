#!/bin/zsh

# 唯一的「跑最新版」入口：构建 → 长期签名安装到 /Applications → 退掉旧进程 → 启动 → 核对构建戳。
# 平时只用这个脚本，不要再自己 open 某个 DerivedData 里的 Amber.app，
# 系统里同时存在多份同 bundle id 的 Amber 时，LaunchServices 会挑到哪份是不确定的。

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
app=/Applications/Amber.app

# 默认 Debug；`./Tools/run.sh Release` 跑优化版（用来判断卡顿是不是 -Onone 的锅）。
# 无论哪个 configuration，安装的都还是 /Applications/Amber.app 这一份。
configuration=${1:-Debug}
if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
    print -u2 "用法：$0 [Debug|Release]"
    exit 1
fi

"$script_dir/build-install-signed.sh" "$app" "$configuration"

# xcodebuild 的产物会被注册进 LaunchServices，也会被 Spotlight 收录，
# 留一份就多一个同 bundle id 的 Amber，双击 / Spotlight / open -b 命中哪份是不确定的。
# 只删「本次构建的那条路径」根本不够，实际漏掉的至少有五种：
#   1. 上一次跑的另一个 configuration —— 跑完 Release 再跑 Debug，Release 那份不会自己消失；
#   2. 别的脚本／随手指定的 derivedDataPath —— build/DerivedDataDist（make-dmg.sh）、build/DerivedDataRelease……
#   3. 忘了带 -derivedDataPath 的 xcodebuild test 和 Xcode 图形界面构建 ——
#      产物落在 ~/Library/Developer/Xcode/DerivedData/Amber-*/Build/Products/*/Amber.app；
#   4. worktree 里子代理各自构建的那份 —— .claude/worktrees/*/build/DerivedData/…/Amber.app；
#   5. 临时目录 —— `-derivedDataPath /tmp/am-test-dd2` 这种随手指定的，
#      以及每个 Claude 子会话自己的 scratchpad：/private/tmp/claude-*/…/scratchpad/dd*/…/Amber.app
#      （子代理为了并行各建各的 DerivedData，一个会话留一份，攒着攒着就是「好几个 Amber」）。
# 所以不按路径删：先问 LaunchServices「你手上都有哪些 Amber.app」（那就是系统里真正会冒出来的那批），
# 再补扫项目树和 Xcode 默认 DerivedData（还没被注册、但迟早会被收录的产物）。
# 动手前核对 CFBundleIdentifier，只删真正是 Amber 的包；下次构建会自动重新生成。
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# dump 里的路径行长这样：`path:    /Applications/Amber.app (0x11008)`。
# 剥掉行首字段名和行尾地址，再要求最后一段正好是 Amber.app
# （用 '/[^ ]*Amber\.app' 取子串的旧写法：路径带空格会被截断，FooAM.app 还会误报）。
registered_am_apps() {
    "$lsregister" -dump 2>/dev/null \
        | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*\) (0x[0-9a-f]*)$/\1/p' \
        | grep '/Amber\.app$' | sort -u
}

typeset -a candidates
while IFS= read -r found; do
    candidates+=("$found")
done < <(registered_am_apps)
# /tmp 用 /private/tmp：BSD find 不会跟着当起点的符号链接走进去。
for sweep_root in "$project_dir" "$HOME/Library/Developer/Xcode/DerivedData" /private/tmp "${TMPDIR:-}"; do
    [[ -n "$sweep_root" && -d "$sweep_root" ]] || continue
    while IFS= read -r -d '' found; do
        candidates+=("$found")
    done < <(find "$sweep_root" -maxdepth 12 -type d -name 'Amber.app' -prune -print0 2>/dev/null)
done

typeset -a swept
for stale in ${(u)candidates}; do
    [[ "$stale" == "$app" ]] && continue
    # 挂载的 dmg 是只读的，删不掉也不该删；卸载后自己就没了。
    [[ "$stale" == /Volumes/* ]] && continue
    if [[ -d "$stale" ]]; then
        stale_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stale/Contents/Info.plist" 2>/dev/null || print '?')
        [[ "$stale_id" == com.changlepan.Amber ]] || continue
    fi
    "$lsregister" -u "$stale" 2>/dev/null || true
    rm -rf "$stale" 2>/dev/null || true
    swept+=("$stale")
done

if (( ${#swept[@]} )); then
    print
    print "已清掉 ${#swept[@]} 份多余的 Amber.app："
    printf '  %s\n' "${swept[@]}"
fi

# 退掉正在跑的旧实例（先好好退，退不掉再杀）。
if pgrep -f "$app/Contents/MacOS/Amber" >/dev/null 2>&1; then
    osascript -e 'quit app id "com.changlepan.Amber"' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -f "$app/Contents/MacOS/Amber" >/dev/null 2>&1 || break
        sleep 0.25
    done
    pkill -f "$app/Contents/MacOS/Amber" 2>/dev/null || true
fi

open -a "$app"

# 核对：真正跑起来的是不是刚装的那份。
sleep 1
running=$(pgrep -lf '/Amber\.app/Contents/MacOS/Amber' | head -1 || true)
installed_commit=$(/usr/libexec/PlistBuddy -c 'Print :AmberBuildCommit' "$app/Contents/Info.plist" 2>/dev/null || print '?')
installed_date=$(/usr/libexec/PlistBuddy -c 'Print :AmberBuildDate' "$app/Contents/Info.plist" 2>/dev/null || print '?')

print
print "已启动：$app"
print "构建戳：$configuration  $installed_commit  $installed_date"

if [[ "$running" != */Applications/Amber.app/Contents/MacOS/Amber* ]]; then
    print -u2 "警告：当前运行的进程不是 /Applications 里那份 —— $running"
    exit 1
fi

# 清扫之后再问一次 LaunchServices：还剩别的 Amber.app 就说明有清不掉的（只读卷、权限），提醒一声。
others=$(registered_am_apps | grep -v "^$app\$" || true)
if [[ -n "$others" ]]; then
    print
    print "注意：系统里还注册了其他 Amber.app，双击/Spotlight 可能打开到旧版本："
    print "$others"
fi
