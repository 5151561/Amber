# 项目约束

## 构建与安装

- Debug 或 Release 不是钥匙串授权是否稳定的关键；关键是始终使用同一个可信的开发证书和稳定的 Designated Requirement。
- 需要构建、安装并运行最新版 Amber 时，统一执行 `./Tools/run.sh`。
- `./Tools/run.sh` 默认 Debug；`./Tools/run.sh Release` 构建优化版（`-O` + wholemodule），用来判断卡顿是不是`-Onone` 造成的。两者都装到`/Applications/Amber.app` 这一份，看完记得跑回`./Tools/run.sh` 换成 Debug。
- `Tools/run.sh` 必须完成长期签名校验，并确保只安装、启动`/Applications/Amber.app` 这一份应用。
- 不要手动启动 DerivedData、临时目录或 worktree 中的 `Amber.app`，也不要使用 ad-hoc 签名产物，避免同 Bundle ID 的多份应用导致钥匙串反复请求授权。
- 看界面、截图、采 AX 树也用 `/Applications/Amber.app` 这一份，别为了「快一点」去开产物目录里的那个。
- 万一系统里又多出了几份（`xcodebuild` 的产物会被 LaunchServices 收录，Spotlight／程序坞里就冒出好几个 Amber）：跑一次`./Tools/run.sh` 即可复原——它会先问 LaunchServices 手上都注册了哪些`Amber.app`，再补扫项目树（含 worktree）和`~/Library/Developer/Xcode/DerivedData`，把`/Applications` 之外、bundle id 确实是`com.changlepan.Amber` 的全部注销并删掉，末尾列出仍清不掉的（只读卷之类）。
- 自己跑 `xcodebuild`（尤其是`test`）一律带`-derivedDataPath build/DerivedData`。别指到`/tmp` 之类的地方：那种产物在被 LaunchServices 收录之前，`run.sh` 是扫不到的。

## 界面层

界面层的骨架是 **AppKit**，SwiftUI 只作为叶子。这五条来自 `design-ref/appkit-rewrite-plan.md` §2，
是整个改造期与改造之后都成立的硬约束：

1. **不再新增 `NSViewRepresentable` / `NSViewControllerRepresentable`。** 方向只能是 AppKit 里挂`NSHostingView`。
2. `NSHostingView` 只能挂在**定尺寸**的槽里，且`sizingOptions = []`（Apple 文档原话：减少布局测量、提升性能；帧比内容小时内容居中）。滚动容器里的单元格不许用`NSHostingView`，除非里面真有 SwiftUI 才能做的控件（先例：`SongsRichCellView`）。
3. 悬浮态、选中态、当前播放指示由 AppKit 视图自己持有并 `needsDisplay`，不许经过`@Published` 绕一圈。
4. 菜单命令走响应链 target-action + `validateMenuItem`；导航意图（前往专辑/艺人）走响应链冒泡，删掉`pendingRoute`。
5. 像素规格照旧取 `MusicMetrics` / `MusicColors`，迁移「换骨架，像素一个不改」（与歌曲表、侧栏两次迁移同一原则）。新增度量要标`[AX]/[PX]/[实测]/[推]` 出处。
6. **先用系统默认值，AX 量到的常量只当验收标尺。** 每条度量落地前先问三问：

   1. 系统 API 能不能直接给这个数（`NSFont.systemFontSize`、`NSTableView.RowSizeStyle`、
      `NSSplitViewItem` 的默认厚度、`NSToolbar` 的标准高、`NSCollectionLayoutSpacing`……）？
      能就用系统的，实测值只写进注释当验收值，不要在 `MusicMetrics` 里立一条常量。
   2. 是不是 Music 自己的设计常量（有 `[实测]` / `[资源]` 出处）？那就留在`MusicMetrics` 当 token。
      （`[实测]` = 对着 Music 量出来的定值，`[资源]` = 取自 Music 的资源包，`[AX]` = 辅助功能树，
      `[PX]` = 截图逐像素量，`[推]` = 没有依据、按惯例推的。）
   3. 是不是补 SwiftUI 内建偏移的 `[推]`？随框架切换一起删——AppKit 里没有那层偏移，
      留着只会把偏移补到反方向去。

   只有默认值与实测确实对不上时才写死，且注释要写明「系统默认 X，实测 Y」。
   同理，实机现象要先验证再照着改：AppKit 的空工具栏不会让标题栏塌（那是 SwiftUI 时代的问题），
   侧栏首次宽度由子控制器 view 的 frame 决定而不是 `setPosition`——这类都属于「系统本来就对」。
