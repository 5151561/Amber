# 项目约束

## 构建与安装

- 构建、安装、运行最新版 Amber 只走 `./Tools/run.sh`。它负责长期签名校验、只装`/Applications/Amber.app` 这一份、并清掉系统里多余的同 bundle id 产物（机制见脚本自己的注释；Spotlight／程序坞里又冒出好几个 Amber 时，跑一次就复原）。钥匙串授权稳不稳跟 Debug／Release 无关，关键是同一个可信开发证书 + 稳定的 Designated Requirement，这两条由`Tools/build-install-signed.sh` 把关。
- `./Tools/run.sh` 默认 Debug；`./Tools/run.sh Release` 构建优化版（`-O` + wholemodule），用来判断卡顿是不是`-Onone` 造成的。两者都装到同一份`/Applications/Amber.app`，看完记得跑回`./Tools/run.sh` 换成 Debug。
- 不要手动启动 DerivedData、临时目录或 worktree 里的 `Amber.app`，也不要用 ad-hoc 签名产物：同 bundle id 存在多份时，LaunchServices 命中哪份不确定，钥匙串还会反复请求授权。看界面、截图、采 AX 树也用`/Applications/Amber.app` 这一份，别为了「快一点」去开产物目录里的那个。
- 自己跑 `xcodebuild`（尤其是`test`）一律带两样：`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`（缺了报 requires Xcode）和`-derivedDataPath build/DerivedData`（指到`/tmp` 之类的地方，产物在被 LaunchServices 收录之前`run.sh` 扫不到）。

## 语言与安全开关

所有 Swift 开关集中在 `Support/SwiftFeatures.xcconfig`（语言模式与严格并发仍在 pbxproj 的
target 级）。现在开着的除了 Swift 6 语言模式 + complete 并发 + approachable concurrency，
还有四个 Swift 7 的 upcoming feature 与 **`SWIFT_STRICT_MEMORY_SAFETY = YES`**。

碰裸指针的新代码按三档选，**不许跳档**（详版与实测依据见 `design-ref/swift-modernization.md` §3）：

1. 能改成安全代码的先改，不标注；
2. 无安全替代但同一个声明全仓用 ≥3 次 → `@safe` 外壳（现成的在 `Amber/Safety/AppKitSafeAccess.swift`）；
3. 一次性的或本质不安全的 → 表达式级 `unsafe`，**必须**写清「不安全在哪、谁保证它安全」。

不要全量套 `MIGRATE` 的 fix-it（会把一、二档一起降成第三档）。标过头有反向哨兵：
`[#UnnecessaryUnsafe]` 在开关关着时也报，所以平时的 warning 基线就能兜住。

## 界面层

界面层的骨架是 **AppKit**，SwiftUI 只作为叶子。以下六条铁律在整个改造期与改造之后都成立，
这里是唯一副本（`design-ref/appkit-rewrite-plan.md` §2 只作引用，要改改这里）：

1. **不再新增 `NSViewRepresentable` / `NSViewControllerRepresentable`。** 方向只能是 AppKit 里挂`NSHostingView`。
2. `NSHostingView` 只能挂在**定尺寸**的槽里，且`sizingOptions = []`（Apple 文档原话：减少布局测量、提升性能；帧比内容小时内容居中）。滚动容器里的单元格不许用`NSHostingView`，除非里面真有 SwiftUI 才能做的控件（先例：`SongsRichCellView`）。
3. 悬浮态、选中态、当前播放指示由 AppKit 视图自己持有并 `needsDisplay`，不许经过共享的可观察状态绕一圈。（这条原来写的是「不许经过`@Published`」——剥离 Combine 之后换成了 `@Observable` 的属性，要守的东西一个字没变：界面自己的显示态不上广播。）
4. 菜单命令走响应链 target-action + `validateMenuItem`；导航意图（前往专辑/艺人）走响应链冒泡，删掉`pendingRoute`。
5. 像素规格照旧取 `MusicMetrics` / `MusicColors`，迁移「换骨架，像素一个不改」（与歌曲表、侧栏两次迁移同一原则）。新增度量要标出处：`[实测]` = 对着 Music 量出来的定值，`[资源]` = 取自 Music 的资源包，`[AX]` = 辅助功能树，`[PX]` = 截图逐像素量，`[推]` = 没有依据、按惯例推的。
6. **先用系统默认值，AX 量到的常量只当验收标尺。** 每条度量落地前先问三问：(a) 系统 API 能不能直接给这个数（`NSFont.systemFontSize`、`NSTableView.RowSizeStyle`、`NSSplitViewItem` 默认厚度、`NSToolbar` 标准高、`NSCollectionLayoutSpacing`……）——能就用系统的，实测值只写进注释当验收值，不在`MusicMetrics` 里立常量；(b) 是不是 Music 自己的设计常量（有`[实测]`/`[资源]` 出处）——留在`MusicMetrics` 当 token；(c) 是不是补 SwiftUI 内建偏移的`[推]`——随框架切换一起删，AppKit 里没有那层偏移，留着只会把偏移补到反方向去。只有默认值与实测确实对不上时才写死，且注释写明「系统默认 X，实测 Y」。

同理，实机现象要先验证再照着改：AppKit 的空工具栏不会让标题栏塌（那是 SwiftUI 时代的问题），
侧栏首次宽度由子控制器 view 的 frame 决定而不是 `setPosition`——这类都属于「系统本来就对」。
