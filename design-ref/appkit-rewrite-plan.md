# Amber 界面层改成 AppKit 骨架 —— 审查与分阶段计划

> 2026-09-05。审查对象：`Amber/Views/**`、`Amber/App/**`、`Amber/Lyrics/**`，对照规格笔记里 Music 1.7 的类型树。
> 这份文件是后续每个阶段开工前要读的总纲；每阶段完工后把「状态」一栏改掉。
>
> **2026-09-17 修订**：§1.4「状态层不用改」的结论已推翻（见该节），据此新增**阶段 9 状态层**。
> 阶段 0–8 的编号、内容与五段补记一律不动——源码里有十处注释按这些编号定位。

## 0. 先纠正一个前提：Music 不是「全 AppKit」，是「AppKit 骨架 + 少量 SwiftUI 叶子」

规格笔记里能定性的部分（[TYPE] 类型树 + [实测]）：

| Music 的块 | 技术 | 出处 |
| --- | --- | --- |
| 主窗分栏 `MainSplitViewController`、侧栏`NativeSidebarViewController`（NSOutlineView）、导航栈`AMPNavigationController`（push/pop） | AppKit | ` 界面逻辑笔记` |
| 歌曲表 `AMPTrackDisplayController` / `TrackDisplayTableView` | NSTableView | `songs 规格` |
| 专辑/歌单详情 `AlbumDetailsViewController : AMPDynamicScrollingViewController`、行`AMPRolloverTableCell` 系 | AppKit（NSTableView 行 + 悬浮态由 tracking area 推） |` 框架清单笔记` |
| 资料库网格 `AMPGridCollectionViewLayout`、艺人页`TracklistLayout` | NSCollectionView 自定义 layout |` 框架清单笔记` |
| 歌词 `SyncedLyricsViewController` | NSViewController + CALayer | `lyrics 规格` |
| 整窗播放器外壳 `MPContentView`（抽屉、rollover、纱罩） | AppKit（`AMPBindableView`） | ` 界面逻辑笔记` |
| 整窗播放器内容 `NowPlayingView`（封面、元数据、传输键、阴影） | **SwiftUI**，挂在 AppKit 壳里 |`nowplaying 规格` §6.5、§9.1 |
| 主页/新发现/广播 `CatalogPagePresenter<Page>`（`@Published` 状态机） | **SwiftUI** 状态对象，宿主`CatalogPageViewController` 是 AppKit |`catalogpage 规格` §1 |
| 艺人目录页 `ArtistDetail*`（`SwiftUI.Environment`、`ScaledMetric`） | **SwiftUI**（新旧双实现） |`artistpage 规格` |

所以正确的目标不是「一行 SwiftUI 都不留」，而是把**方向倒过来**：现在是 SwiftUI 树里嵌 AppKit（`NSViewRepresentable`），要改成 **AppKit 树里嵌 SwiftUI 叶子（`NSHostingView`，定尺寸、`sizingOptions = []`）**。窗口、分栏、导航、工具栏、菜单、表格、网格、悬浮层这些「骨架」一律 AppKit；只有内容简单、结构固定、不参与滚动的小块才允许留 SwiftUI。

## 1. 审查：现在的问题为什么都是「没搓好」

### 1.1 已经量到的证据

- 最近一条提交（ff2acc8）的量具结果：主页触控板滑动 **44.7 fps**，主线程 73.5% 忙，其中 **SwiftUI 每帧重新布局 26.4%**、拖拽边距 8.4%。根因是整扇窗是一棵 SwiftUI 树，滚动时窗口每个显示周期要把响应者树整个走一遍，树多大每帧就多贵。`LazyVStack` 只是缓解。
- `PlayerController` 里为了压掉「整个界面每秒重画十次」专门拆出`PlaybackClock`，`AppState` 注释里明写「子 store 的变化不再转发」——这是在跟 SwiftUI 的失效传播打补丁。AppKit 里订阅是显式的，这类问题不存在。
- 详情页头部的横竖排要靠 `GeometryReader` 量容器宽（`DetailViews.swift` 注释：量自己会「无限重排、主线程卡死」）。
- 已经换成 AppKit 的三块，每一块换完都是「三处硬伤一起没了」：歌曲表（7de8da4：列拖动高亮、插图跨行、列不可拖宽）、歌词（3709e74）、侧栏（工作区未提交：方向键、VoiceOver 选中态、右键预选、选中色不吃 tint）。

### 1.2 主壳 `MainView.swift` 里堆着的绕路（每一条都是 AppKit 原生就有的能力）

| 绕路 | 对应的 AppKit 原生做法 |
| --- | --- |
| `navigationSplitViewColumnWidth` 只能挂在列根上、写在内部不生效 |`NSSplitViewItem.minimumThickness / maximumThickness` |
| `.inspector` 必须挂在`NavigationSplitView` 本身上，写进`detail:` 静默失效 |`NSSplitViewItem(inspectorWithViewController:)`（macOS 11+，已核文档） |
| 迷你播放器用 `anchorPreference` + `overlayPreferenceValue` + `GeometryReader` 算位置、还要`.animation(nil)` 按住漏进来的事务 | 一个子视图 + 约束到内容列，`NSGlassEffectView` 做胶囊 |
| 整窗播放器常驻 + `offset` 位移、`ignoresSafeArea` 位置有讲究、`.task` 归零问题 | 常驻`NSViewController` 子控制器 +`NSAnimationContext` 位移 |
| Esc 关闭要挂零尺寸隐形按钮（`.onExitCommand` 收不到） | 响应链`cancelOperation(_:)` |
| 空格暂停要自己判断第一响应者是不是 `NSTextView` | 菜单 key equivalent 与响应链本来就按此分流 |
| 工具栏「播放中」期间要留 1pt 占位项撑高度、还得 `sharedBackgroundVisibility(.hidden)` 去掉自动玻璃 |`NSToolbarItem.isHidden`（macOS 15+，已核文档） |
| 菜单命令拿不到 environment，要另开 `@ObservedObject` 小视图 |`validateMenuItem(_:)` + 响应链 target-action |
| `NavigationStack` 返回时 destination 重建，滚动位置丢（design brief 3.3 要求保留） | 自己的导航控制器把 VC 留在栈里（Music 的`AMPNavigationController` 就是这么做的） |
| 「前往专辑」要经 `appState.pendingRoute` 登记再由 MainView 入栈 | 响应链`doGoToAlbum(_:)` 一路冒泡到导航控制器 |

### 1.3 各文件现状与去向

| 文件 | 行数 | 现状 | 去向 |
| --- | ---: | --- | --- |
| `App/AmberApp.swift` | 208 | SwiftUI `App` 场景 +`.commands` | `NSApplicationDelegate` + 代码建主菜单 +`MainWindowController` |
| `Views/MainView.swift` | 53 | 主壳已搬进`Views/Shell/`，只剩曲目拖入落点`SidebarTrackDrop` | `MainSplitViewController`（NSSplitViewController）+ `ContentNavigationController`（已完成）；落点在阶段 8 清场 |
| `Views/SidebarOutline.swift` | 625 | **已是 NSOutlineView**，外面还套一层`NSViewRepresentable` | 去掉宿主壳，直接做侧栏`NSViewController` |
| `Views/MiniPlayerView.swift` | 447 | SwiftUI 胶囊 + 手势 |`MiniPlayerView: NSView`（NSGlassEffectView + NSButton + 自绘进度条） |
| `Views/NowPlaying/*` | ~1900 | SwiftUI 整屏 + 歌词 AppKit 桥接 | AppKit 壳（`NowPlayingContainerViewController`）+ SwiftUI 内容叶子（与 Music 同构，最后做） |
| `Views/Catalog/*` | ~1500 | `LazyVStack` + `LazyHStack` 货架 |`NSCollectionView` 组合布局，段用 orthogonal 横滚（已核`NSCollectionLayoutSectionOrthogonalScrollingBehavior`，macOS 10.15+） |
| `Views/DetailViews.swift` | 776 | SwiftUI 头部 +`TrackList` | 每页一张`NSTableView`：第 0 行是头部，其余是曲目行 |
| `Views/Components/TrackRow.swift` + `TrackList.swift` | 547 | 每行两个`@State` 悬浮态 |`NSTableRowView` + `NSTableCellView`，悬浮走 tracking area（照`SongsTableCells` 的分层） |
| `Views/LibraryViews.swift` | 518 | 专辑页与艺人页已搬走（`LibraryAlbumsViewController` / `LibraryArtistsViewController`）；剩最近添加、所有播放列表与共用的网格件仍是 SwiftUI | 专辑网格`NSCollectionView`（`MusicMetrics.Page.grid*` 就是`AMPGridLayoutModel` 的数，已完成）；艺人页`NSSplitView` + 表格（已完成）；最近添加 = 带段头的 collection view |
| `Views/SearchView.swift` + 落地/结果 | ~900 | SwiftUI；搜索框已是`NSSearchField` | 工具栏`NSSearchToolbarItem`；结果页 collection view |
| `Views/PlayerInspectorView.swift` | 212 | SwiftUI 面板 | inspector 列的`NSViewController`，歌词 VC 直接当子控制器，待播清单`NSTableView` |
| `Views/Components/SongsTable*.swift` | ~2800 | **已是 NSTableView**，宿主壳`SongsTableHost` 已去掉（页面是`Shell/LibrarySongsViewController`），富单元格是`NSHostingView` | 保留；富单元格可以后期逐个 AppKit 化 |
| `Views/SettingsView.swift`、`QQLoginView.swift`、`SongsTableSettings.swift` | ~1400 | SwiftUI 表单，宿主已是`Shell/SettingsWindowController` / `AuxiliaryWindows`；`SettingsView.swift` 里只剩五张 pane 与草稿模型，SwiftUI`TabView` 壳已删 | 留 SwiftUI 叶子，宿主换成`NSWindowController`（设置窗`NSTabViewController(.toolbar)` 正好就是 Music 那种「标题 = 当前 tab」的偏好窗）（已完成） |
| `Lyrics/**` | ~5000 | **已是 AppKit + CALayer** | 保留；`SyncedLyricsView` 那层`NSViewControllerRepresentable` 删掉，改直接持有 VC |
| `DesignSystem/*` | ~1460 | 度量与颜色 token，`NSColor` 双份已经有 | 保留，补`NSFont` token |
| `Models / Providers / Services / Player / AmberTests` | — | 与界面无关 | **一行不动** |

### 1.4 状态层的结论：要改（2026-09-17 推翻原结论）

> **原文（2026-09-05）是**：「`AppState / PlayerController / LibraryStore / …` 都是
> `ObservableObject + @Published`，Combine 的 `$prop.sink` 在 AppKit 里直接能用，而且比
> SwiftUI 更好：谁订阅谁更新，不存在「一个 @Published 变了整棵树重算」。」
>
> 那句话本身没错——它说的是「比 SwiftUI 的 `@EnvironmentObject` 整树失效更好」，这一点
> 到今天仍然成立。**过期的是它的结论**：当时的备选只有「Combine」与「SwiftUI 整树失效」
> 两个，而 Swift 6.2 起多了第三个，它在「谁订阅谁更新」这条上与 Combine 平齐，
> 在别的地方更好。

现在的结论：**剥离 Combine，状态层换成 `@Observable` + `Observations` +
`swift-async-algorithms`**。理由是三条实测（2026-09-17，Xcode 27 beta / Swift 6.4，
部署目标 macOS 26）：

1. **`Observations` 的失效粒度与 `$prop.sink` 同级，而且自带两样 Combine 要手写的东西。**
   [实测] 订阅后先发一次当前值（等同 `$prop`，现有 `.dropFirst()` 一对一保留）；
   **同一 tick 连写 1→5 只收到 5**（自动合并）；**Equatable 属性连写三次同值只发一次**
   （相邻去重，等于内建 `removeDuplicates()`，全仓 61 处里大半可直接删）。
   非 Equatable 不去重，那些仍要 `removeDuplicates(by:)`。
2. **时序从 willSet 翻成 didSet。** `@Published` 在值变**之前**发，`Observations` 在
   **之后**发。[reactive-ui-review.md §2.1] 记的 `AppState.pendingRoute` 清空失效
   （`= nil` 在外层赋值落存储之前就跑完，随后被覆盖）正是 willSet 语义的产物——换过去
   这一类 bug 从根上没有了。代价是每个按 willSet 时序写过的消费方都要重新核对。
3. **`.receive(on: DispatchQueue.main)` 整类消失**（全仓 64 处）：`for await` 循环体跑在
   所在 actor 上，消费方是 `@MainActor` 就已经在主线程。

代价与边界，一并记在这里免得实现时再争：

- **操作符要引第三方。** [实测] 标准库与 Foundation 都**没有** `debounce` /
  `removeDuplicates` / `merge` / `chunks`。需引 `apple/swift-async-algorithms` 1.1.5，
  它连带拖入 `swift-collections` 1.6.0——**本仓从零依赖变成两个依赖**，进签名与打包流程。
- **`merge()` 最多 3 路**（第 4 个参数报 `extra argument in call`）。现场唯一那处
  `Publishers.MergeMany`（`Shell/CatalogPageViewController.swift`）恰好 3 路，可直接换；
  再多要用 `AsyncChannel` 扇入。
- **`@Observable` 的依赖是「渲染时记录读了哪些属性」**，从未渲染过的视图不注册任何依赖。
  与记忆 `am-hidden-hostingview-stops-updating` 是同一个坑的两面，收起的分栏列、
  滚出屏幕的表格行都要专门验。
- **事件流不归它管。** `PassthroughSubject` / `CurrentValueSubject` 那几处（`LibraryStore`
  的 `changes(affecting:)`、`PlayQueueModel` 的两个 `didChange`）是**事件广播**不是状态观察，
  `@Observable` 替代不了，换 `AsyncChannel`。判据：消费方关心的是「发生了一次」还是
  「现在的值是什么」。
- `PlayerControlsState / NowPlayingMetadata / SongsTableColumns / SongsTableSort` 这些
  **值类型视图模型原样不动**（这一条原文仍然有效）。
- 测试目标（`AmberTests`，1089 个方法）是整轮改造唯一的自动化护栏，**必须一直绿**；
  其中 6 个文件 import Combine、9 处 `.sink`、14 处 `XCTestExpectation` 要跟着改。

落地见 §3 的**阶段 9**。原 §3 阶段 8「清场」里那条「删 `environmentObject` 注入链」
归并进阶段 9 一起做。

## 2. 目标结构

```
AmberApp (NSApplicationDelegate)                       主菜单在这里用 NSMenu 建
└── MainWindowController : NSWindowController        titlebarAppearsTransparent + fullSizeContentView + NSToolbar
    └── RootViewController                           窗口根：NSVisualEffectView(.contentBackground) 铺满
        ├── MainSplitViewController : NSSplitViewController
        │     ├── sidebar   : SidebarViewController          NSOutlineView（现有 SidebarOutline 去壳）
        │     ├── content   : ContentNavigationController    自己的 push/pop 栈，VC 常驻、滚动位置保留
        │     │     ├── CatalogPageViewController           NSCollectionView 组合布局（主页/新发现/广播）
        │     │     ├── PlaylistDetailViewController        NSTableView（头部行 + 曲目行）
        │     │     ├── AlbumDetailViewController
        │     │     ├── ArtistDetailViewController
        │     │     ├── LibrarySongsViewController          现有 SongsTable 去壳
        │     │     ├── LibraryAlbumsViewController         NSCollectionView 网格
        │     │     ├── LibraryArtistsViewController        NSSplitView + NSTableView + 详情
        │     │     ├── LibraryRecentlyAddedViewController  带段头的 collection view
        │     │     ├── LibraryPlaylistsViewController
        │     │     ├── SearchViewController                落地页 / 结果页两个 collection view
        │     │     └── …
        │     └── inspector : PlayerInspectorViewController NSSplitViewItem(inspectorWithViewController:)
        │           ├── SyncedLyricsViewController（现有）
        │           └── PlayQueueViewController             NSTableView
        ├── MiniPlayerView : NSView                          NSGlassEffectView 胶囊，约束到 content 列中线
        ├── NowPlayingContainerViewController                常驻，收起时位移到窗外
        │     ├── backdrop  : NowPlayingBackdropView (CALayer)
        │     ├── content   : NSHostingController<NowPlayingContent>   SwiftUI 叶子，与 Music 同构
        │     ├── hosted    : SyncedLyricsViewController / TrackSectionsPlatterView
        │     └── chrome    : 四角胶囊（NSGlassEffectContainerView）
        └── ToastView : NSView
```

铁律：见 `AGENTS.md`「界面层」一节（六条，那里是唯一副本；要改改那边，别在这里再抄一份）。

## 3. 分阶段（每阶段都能 `./Tools/run.sh` 跑起来、AmberTests 全绿）

| 阶段 | 内容 | 关键 API | 验收 | 状态 |
| --- | --- | --- | --- | --- |
| **0** | 把工作区里侧栏 NSOutlineView + `Window/UtilityWindow` 那份 diff 提交；量一次基线帧率留档（`/tmp/am-perf.txt`） | — | 基线数据在 | 未开始 |
| **1 壳** | `NSApplicationDelegate` + 主菜单；`MainWindowController` + `NSSplitViewController`（sidebar / content / inspector 三项）；`ContentNavigationController`（push/pop、`transition(from:to:)`、返回前进、VC 常驻）；`NSToolbar`（标题项、搜索项、筛选项、`isHidden` 让位）；窗口根`NSVisualEffectView`。**过渡期**每个页面先用`NSHostingController` 原样包起来挂进去（SwiftUI 页面暂时当叶子），迷你播放器与整窗播放器同样先包。 |`NSSplitViewItem(sidebarWithViewController:)`、`(inspectorWithViewController:)`、`NSToolbarItem.isHidden`、`NSViewController.transition` | 与 Music 的 AX 树对位：`AXSplitter` + 面板列`[1212, 33, 258, 923]`；⌘L/空格/Esc/⌃⌘S 全走响应链；返回上一页滚动位置保留 | **已完成（壳的数值已对上，等用户看外观）** |
| **2 迷你播放器** | `MiniPlayerView: NSView`：`NSGlassEffectView(.regular)` 胶囊、传输键`NSButton`、中央块自绘（封面`NSImageView`、两行`NSTextField`、进度条`CALayer`）、`NSTrackingArea` 悬浮变形、`AVRoutePickerView` 直接放 |`NSGlassEffectView`、`NSGlassEffectContainerView`（macOS 26） | `glyph-diff.py` 对`design-ref/ui-spec/pages/*.png` 逐区域比；两态都是 700 宽（`pages/*.json` 实测`[486.5, 883, 700, 54]`，计划里那句「播放 753」是旧估值） | **已完成（待实机验收）** |
| **3 目录页** | 主页/新发现/广播换 `NSCollectionView` + `NSCollectionViewCompositionalLayout`：每段一个 section，货架用`orthogonalScrollingBehavior = .continuous`（Music 的货架不吸附；翻页箭头自己按列算，见 §5），七种卡型各一个`NSCollectionViewItem`，段头是 supplementary view；`CatalogPageState / CatalogSection / CatalogItem` 模型原样用。悬浮播放键用 tracking area | 组合布局、`NSCollectionViewDiffableDataSource` | 主页触控板滑动 p90 ≤ 8.4 ms（120 fps），用`PerfScrollHarness` 的「观察」模式量 | **已完成（版式与帧率已核，用户已验悬浮，等看外观）** |
| **4 曲目行 + 详情页** | `TrackRow` → `TrackRowView: NSTableRowView` + 三种形态的`NSTableCellView`（专辑 / 歌单 / 资料库），悬浮由行视图推给格子；歌单/专辑/艺人详情 = 一张`NSTableView`，第 0 行头部（高度由`heightOfRow` 给，横竖排按表宽判、不再需要 GeometryReader）；`TrackActionsMenu` 改`NSMenu` | `NSTableView` 变高行、`NSMenu` | 点开歌单不再有「转圈不动」的回环；专辑页对`album-detail.png` 像素比 | **已完成（待用户看外观）**：曲目行 + 菜单、歌单/专辑/本地列表三页照计划走表格；**艺人页没有走表格**，见下面那条更正 |
| **5 资料库四页 + 搜索** | 专辑网格 / 所有播放列表 → collection view 网格（`Page.gridItemMinWidth = 183` 等已是`AMPGridLayoutModel` 的值）；艺人 →`NSSplitView` + 表格；最近添加 → 分段 collection view（段头吸顶联动标题）；搜索落地/结果页 → collection view | 同上 | 各页对`pages/*.png` | **已完成（待用户看外观）**：资料库四页 + 所有播放列表 + 目录二级页 + 搜索两页全部走 AppKit，网格 cell 也去掉了`NSHostingView`。见下面那条补记 |
| **6 整窗播放器** | AppKit 壳：背景换现成的 `MiniPlayerBackdropMetalView`、位移动画（已在 `NowPlayingHostController`）、rollover 计时、四角胶囊 `NSGlassEffectView`、右半区抽屉复用 `InspectorContainerViewController`（沉浸档）、歌词 VC 直接当子控制器；封面 / 元数据 / 传输键那一块**留 SwiftUI**、装进定尺寸槽（Music 同构）。三处决定见下面那条补记 | `NSAnimationContext`、`NSGlassEffectView`、`NSTrackingArea` | 收起后 CPU ≈ 0；展开位移与 Music 的 `transitionResponse/Damping` 一致；`-dumpviews` 迁移前后内容列 frame 一个不差 | **已完成（待用户看外观）** 2026-09-17 |
| **7 附属窗** | 设置窗 `NSTabViewController(tabStyle: .toolbar)`，五个 pane 是`NSHostingController`；QQ 登录 sheet、显示选项面板（`NSPanel`）同法 | — | 设置窗 AX 树与`settings 规格 ` 对位 | **已完成**：三扇都归`Shell/AuxiliaryWindows`；旧 SwiftUI`Settings` 场景连同`SettingsView` 壳、`AppState.settingsTab` 已于 2026-09-07 删净 |
| **8 清场** | ~~删 `PerfFlags / PerfScrollHarness / PerfWindowConfigurator`~~（已于 2026-09-07 单独清掉）、`ContentColumnBoundsKey`、`SidebarTrackDrop`、所有`*Host`/`*Representable`、~~`environmentObject` 注入链~~（归并进**阶段 9**）；README 架构段改写；AGENTS.md 写入 §2 的铁律 | — |`grep -rn Representable Amber` 为 0 | 未开始 |
| **9 状态层** | 剥离 Combine：23 个 `ObservableObject` → `@Observable`，167 个 `@Published` 去壳；AppKit 侧 112 处 `.sink` → `Observations` + `TaskBag`；`PassthroughSubject`/`CurrentValueSubject` → `AsyncChannel`；`.receive(on:)` 64 处整类删掉；`SearchFieldBinder` 与 `RemoteControlServer.remoteChanges` 两个 Combine 形状的公共 API 先行改造；连同阶段 8 的 `environmentObject` 注入链一起清 | `Observation.Observations`、`swift-async-algorithms` 1.1.5（`debounce`/`removeDuplicates`/`merge`）、`AsyncChannel` | `grep -rn "import Combine" Amber` 为 0；`AmberTests` 全绿；每批 `./Tools/run.sh` 实机 | 未开始 |


> **阶段 4 的一处更正（2026-09-06）**：计划原写「歌单/专辑/**艺人**详情 = 一张 `NSTableView`」，
> 艺人页这一条错了。Music 的目录艺人页**不是详情表格，是一张目录页**：容器
> `ArtistDetailPageView` 与主页/新发现/广播共用同一台`CatalogPagePresenter`
> （`artistpage 规格` §0 的边界那段）。照 `design-ref/ui-spec/pages/catalog-artist.png`
> 实测，它是三段：满幅艺人大图 hero（图上艺人名 + ⓘ / ▶ / ★ 三枚圆键）→「最新發行 + 熱門歌曲」
> 并排一条带 →「專輯」货架。所以 Amber 也同构：`ArtistDetailViewController` 是
> `CatalogPageViewController` 的子类、吃`ArtistPageModel`；阶段 3 的目录页引擎顺势泛化了三处
> （模型解耦成 `CatalogPageModelProviding`、`showsPageTitle`、`extendsUnderTitlebar`），
> 新增 `.artistHero` / `.artistBand` 两种段布局，像素在`MusicMetrics.ArtistPage`。
> 顺带补了「收藏艺人」（`LibraryStore.favoriteArtistIDs`，hero 上那枚 ★ 要用）。

> **阶段 5 的补记（2026-09-08）**：
>
> 1. **状态行以前是漏记的**：「最近添加」上一轮就已经是 `LibraryRecentlyAddedViewController`（分段
>    collection view），只是状态列没跟着改。这一轮补上了它一直缺着的「标题栏标题跟着滚动联动当前
>    段名」——判据换成直接问布局要段头的 frame，不再走 SwiftUI 那套 preference key。
> 2. **网格 cell 这一轮才真的去掉 SwiftUI**。阶段 5 前半的三页（专辑 / 最近添加）虽然容器换了
>    `NSCollectionView`，cell 里却还是`NSHostingView` 包`LibraryAlbumCard`——那是**违反铁律 2** 的
>    过渡形态。现在卡片是纯 AppKit（`Shell/LibraryGridCards.swift`），零件直接复用目录页那套
>    （`CatalogArtworkView` / `CatalogPlayButton` / `CatalogCardKit.label`），悬浮由 collection view
>    一处 hitTest 分发（滚轮不发 `mouseMoved`，所以不能每张卡各挂 tracking area）。
> 3. 顺手修回了上一轮迁移丢的两处：专辑页的 ☰ 挂的是空 `NSMenu()`、排序写死按名字升序
>    （`model.sort` 根本没人读）；专辑页的空态也没了。
> 4. **目录二级页**（「查看全部 ›」的落点）四种形态收在 `Shell/CatalogRoomViewController.swift` 一台
>    引擎里：专辑网格 / 歌单网格 / 最近播放 / 分类浏览。卡片一张新的都没写，全是目录页的方卡
>    （`CatalogSquareItem`）。房间页头`CatalogRoomHeaderView` 也换成了 AppKit，
>    `TrackListPageController` 的`.room` 头与它共用一份。
>    网格口径并到了有出处的 `MusicMetrics.Page.grid*`（[实测]`AMPGridLayoutModel` 的 183/10/6），
>    旧的 180–230 + 20 + 24 那套手感值不再有——**版式因此有肉眼可见的变化**（列宽 ~212→~220、
>    行距变紧、封面没了那层 Amber 自己加的投影），这是并口径的必然结果，不是走样。
> 5. **引擎为搜索页新增了两处**（其它四页一个像素没动，已用 `-dumpviews` 核过）：
>    段布局 `.topResults` + 卡型`.topResult`（热门搜索结果的横卡网格，Music
>    `TopSearchLockupComponentItem` / `TopSearchGridLayoutConfiguration` §2 的复刻，
>    尺寸照 Amber 旧版 `TopSearchLockupView.swift` 原样搬）；子类开关`firstSectionTopGap`
>    （默认 0，搜索结果页拨 14）。另外 `CatalogItem` 多了`onOpen` / `openMenuTitle`
>    ——资料库派生的艺人没有 `Route` 可推，从前把跳转挂在`onPlay` 上，副作用是悬浮
>    浮出一颗播放键、按下去却是跳转。视频卡的时长角标是 opt-in 的（只在 `badge != nil`
>    时画），主页/新发现那两处不设 badge，一笔不画。
> 6. **搜索两页**：结果页走的还是艺人页那条路——`SearchResultsModel` 是第三个吃
>    `CatalogPageModelProviding` 的数据源，`SearchResultsViewController` 只是`CatalogPageViewController`
>    的子类拨三个开关。落地页（最近搜索 + 浏览类别砖块）自己一张 collection view。
>    `SearchView.swift` 里那套照 §4.1.x 复刻的提交链（去抖、同词去重、切范围重提、Option-Enter
>    切音源、最近搜索、竞态防护）整个搬进了 `SearchResultsModel`，标题栏那两件（搜索框 + 范围分段
>    控件）本来就是 AppKit，没动。

> **检查器面板的补记（2026-09-09）**：右侧那条检查器列不在任何一个阶段里——阶段 1 只把它当
> 「`NSHostingController` 包一片 SwiftUI 叶子」的过渡形态带过去了。这一轮照
> `playqueue 规格` §3 与 `inspector 规格` §1/§2 把它补齐：
>
> 1. **容器**换成 `InspectorContainerViewController`（对应`MusicInspectorContainer`）：两个面板
>    控制器 `init` 时就建好并`addChild`，切档是把新面板插在旧面板**底下**做 alpha 交叉淡入
>    （§1.4），不是抽换 `rootView`——待播清单变成有滚动位置、有选区、有定时器的
>    `NSViewController` 之后，抽换那条路根本装不下它。宿主补上了 §2.1 的
>    `allowsFullHeightLayout` / `springLoaded`，§2.4 的隐藏偏好`animate_inspector_expansion`，
>    以及 §2.8「拖到窗口右缘悬停展开必定停在播放列表」。
> 2. **待播清单**换成 `PlayQueueViewController`：`NSTableViewDiffableDataSource` 四分区
>    （历史 / 队列 / 继续播放 / 自动连播）、§3.5 那张五档行高表、三种分区头 + 三种信息行 +
>    空状态行、顶部「自动连播 / 混音」按钮条（窄了退成只剩图标）、滑动「移除」、5 秒回滚、
>    拖入落点。文案全部实测 Music 的 `zh_CN.lproj/UserInterface.strings`。
> 3. **模型层**新增 `PlayQueueModel`（对应`ITPlayQueueModel`）；`PlayerController` 补
>    `queueOrigins` / `queueSource` 与移除、重排、清除三个编辑动作。顺带订正一处语义：
>    `playLast` 从「插到整队队尾」改成「插到 Up Next 段末尾」（§2.1 分区语义 + §3.4 快照顺序）。
> 4. **迷你播放器窗的抽屉**也换到同一台容器上（§4：Music 的迷你/全屏与主窗复用同一个
>    `MusicInspectorContainer`），一扇窗一份实例。于是 SwiftUI 那份待播清单没有宿主了，
>    `PlayerInspectorView` 瘦成只剩歌词并改名`InspectorLyricsView`。
> 5. 没做完的记在 [todo.md](todo.md) §3–§6（自动连播、私人 FM 与心动模式、惯性滚动吸附、三处小缺口）。

> **阶段 6 开工前的三处决定（2026-09-17）**：勘察发现计划里写的活有三件仓库里已经有现成的，
> 三条都由用户拍板，记在这里免得实现时又按旧计划走。
>
> 1. **右半区抽屉 = `InspectorContainerViewController` 的第二个实例，不是新写的待播盘表格。**
>    计划原写「待播盘 `NSTableView`」，那是漏了 `inspector 规格` §4 的实读结论：`MPContentView`
>    自己持有 `inspectorContainer`(+88) 与 `inspector`(+96)，**「窗口右侧栏」与「全屏播放器抽屉」
>    是同一个容器类的两个实例**，全屏那份打开 `isImmersionMode`（§4.2：它与 `isMiniPlayerMode`
>    是同一个开关的正反面，一起传给歌词控制器），容器本身 `includeBackdrop = false`
>    （§4：**两处创建点都传 false**），全屏那层玻璃来自把容器套进 `AMPVibrantContainerView`（§4.1）。
>    所以 `TrackSectionsPlatter.swift` 与 `FullWindowHostedContentView` 整个删掉，platter 的玻璃外形
>    与 `MusicMetrics.NowPlaying.platter*` 度量保留，里面换成 `PlayQueueViewController`。
>    **代价是盘内外观会变**（四分区、§3.5 那张行高表、顶部按钮条），这是用户认下的。
>    顺带订正 `InspectorContainerViewController` 里那句「传 true 的调用方在全屏播放器侧」——
>    §4 实读两处都是 false。
> 2. **背景换成 `MiniPlayerBackdropMetalView`**（`TSLBackdropMetalView` 的复刻，数值逐条实测落在
>    `MusicMetrics.Backdrop`，文件头本来就写着「迷你/全窗播放器底衬」）。纱罩 `0.7 − 0.4p`、
>    律动 `10.5 − 9p` 正是 nowplaying 规格 §2.1 那两条，减弱动态、遮挡暂停、换图 0.5s 交叉淡化
>    都在里面。**整窗背景外观因此会变**：现在那份是 Amber 自拟的 12×12 均值场 + 60 模糊
>    （`NowPlayingBackdrop.swift` + `NSImage.amberBackdropField` + `NowPlaying.backdrop*` 那一组），
>    一并删净——留着的那份反而是没有实测出处的那一份。
> 3. **内容列（封面/元数据/时间行/传输行）留 SwiftUI**，照计划原文与 Music 同构。但**槽位契约反过来**：
>    列宽由容器算好传进去，不再让 SwiftUI 自己 `GeometryReader` 量；四角 overlay、`onContinuousHover`、
>    背景、粒子层全部移出 SwiftUI；`primaryArtworkCenterY` 由容器按同一个列宽自算
>    （堆叠常量本来就都在 `MusicMetrics.NowPlaying`），`NowPlayingCoordinateSpace` 与两个
>    `PreferenceKey` 删掉。`AmberTrackBar` / `PlaybackTimeReader` 因此保留。
>
> 另外两条顺手做的：rollover 的停留计时从现在的 `[推] 3s` 换成迷你窗那份实测值
> （窗内静止 3.75 = `kMouseInterestTimeoutInSeconds`、离开窗口 0.3 =
> `kMouseInterestExitingWindowTimeoutInSeconds`，miniplayer 规格 §11.1），同一条 §2.3 机制两处统一；
> 歌词那一格换成 `SyncedLyricsViewController` 直接当子控制器之后，`SyncedLyricsView` 与
> `AirPlayButton` 这最后两处 `NSViewRepresentable` 一起没了——阶段 8 那条
> `grep -rn Representable Amber` 为 0 会在本阶段提前达成。

> **阶段 6 的收尾（2026-09-17 当天）**：两批（容器＋胶囊 / 沉浸档＋歌词 VC）并行落地之后，
> 集成时实机抓出三处，都不是子代理的分工边界内能看见的：
>
> 1. **收起时没停歌词的每帧驱动**。整窗播放器收起是「位移出窗 + alpha 0」，既不走
>    `viewWillDisappear` 也不走 `viewDidHide()`，两条自动通路都盖不住它。容器按 `isPresented`
>    推 `backdrop.isActive` / `chrome.isActive` 时漏了 `drawer.isActive`，补上。
> 2. **背景在没有封面时整块透明**。`MiniPlayerBackdropMetalView` 的安全降级是「纹理拿不到
>    就是一块透明的空视图」——迷你窗缺省走毛玻璃那一支，这条降级从没露过面；整窗这边它是
>    唯一的背景，于是资料库直接从播放器底下透上来。补回旧 SwiftUI 版那层空态底
>    （[PX] 反算自 Music 空态截图的 `#6E6F72`），有封面时让位给 Metal 那层。
>    **这条是 `-dumpviews` 看不出来的**：它只给 frame，Metal 与 SwiftUI 的内部都不进树，
>    背景这类必须截屏看（见记忆 `am-dumpviews-verification`）。
> 3. **「待播清单 → 歌词」切回去一片空白**。盘的收起动画收尾时连 `drawer.view` 一起藏，
>    而那时抽屉里装的已经是歌词面板；再手动开关一次会走 `fadeDrawer` 把 `isHidden` 掰回来，
>    所以症状是「要开关一次才显示」。盘动画改成只管玻璃盘（队列档时抽屉在玻璃**里面**，
>    藏玻璃本来就连它一起藏了），换档时抽屉恒可见、alpha 复位。
>
> 另有一处是验收口子自己造出来的假故障，记下来免得再踩：把抽屉状态**预置**成「一上来就开着」，
> 队列表会在 0 尺寸下走一遍布局，AppKit 抛 `NSInternalInconsistencyException`
> **“The row at 0 is not floating.”**（`NSTableRowData.m:6900`）整个 App 在 `didFinishLaunching`
> 里就死了——而且 AppKit 把异常吞了，`stderr` 一个字都没有，靠 `lldb -o "breakpoint set -E objc"`
> 才抓得到（同 AGENTS.md「实机现象要先验证再照着改」）。真实路径（窗口布好局之后点底栏那颗键）
> 没有这个问题，所以验收口子改成**走点击同一条路**：第一次有效布局之后再 `setInspectorOpen`。
> `-nowplaying -queue -lyrics` 三个一起给 = 「开在队列档再切到歌词档」，就是上面第 3 条那一步。


顺序的理由：壳先做，因为其余一切挂在它上面，而且阶段 1 做完就已经消掉 §1.2 表里的全部绕路；目录页第二，因为它是量到的掉帧现场；整窗播放器最后，因为它最大、而 Music 自己在那里也是 SwiftUI，收益/成本比最低。

## 4. 落地方式

- 每个阶段一个分支，合回 main 前必须：`./Tools/run.sh` 起得来、`xcodebuild test` 绿、对应页面`ax-dump` / `glyph-diff` 过。
- 动手活按文件所有权切批次交给子代理并行（见记忆 `delegate-to-opus-few-agents`）：阶段 1 一批；阶段 3 可切成「布局 + 数据源」与「七种卡型 item」两批；阶段 4 切「行视图」与「三个详情 VC」两批；阶段 5 四页各一批。
- 过渡期允许 SwiftUI 页面被 `NSHostingController` 包着挂在 AppKit 导航栈里，但**新写的代码一律 AppKit**；每个被包着的页面在对应阶段被替换。
- 度量从 `MusicMetrics` 取，新增度量要标`[AX]/[PX]/[实测]/[推]` 出处，与现在一致。

## 5. 风险与预留

- ~~**`NSGlassEffectView` 的 Style 枚举文档只给了类型名**~~ 阶段 2 已查 SDK 头文件（`NSGlassEffectView.h`）：`NSGlassEffectViewStyle` 只有`regular`（Standard glass effect style）与`clear`（Clear glass effect style）两档，与 SwiftUI`Glass.regular` / `.clear` 一一对应；迷你播放器旧版是`amberGlass(clear: false)`，AppKit 侧取`.regular`。另：`contentView` 由`NSGlassEffectView` 用约束钉满自己（独立探针实测：TAMIC 被置 false、frame = 玻璃的 bounds，命中测试正常穿到 contentView 的子视图），所以内部可以放心手排 frame。
- ~~**组合布局的 orthogonal 横滚在 macOS 上的惯性与翻页对齐**要实测~~ 阶段 3 批 A 已用独立探针实测（macOS 27.0 build 26A5425a；结论同时抄在 `Amber/Views/Shell/CatalogPageViewController.swift` 文件头）：

  1. **不用 `.groupPaging`**，用`.continuous`——Music 的货架是触控板自由滑、不吸附；翻页箭头照旧按**列**算（`round(offset / pitch) ± step`），与旧 SwiftUI 版`scrollPosition(id:)` 同一语义。
  2. orthogonal 段布局内部造的那个 `_NSCollectionScrollView` 是 **collection view 的直接子视图**，从该段任一可见 item 的`view.enclosingScrollView` 就能拿到（实测`scroll.superview === collectionView`）；`contentView.animator().setBoundsOrigin(_:)` 能平滑驱动它；给它的 clip view 打开`postsBoundsChangedNotifications` 后`NSView.boundsDidChangeNotification` 每帧都到，箭头显隐只看真实几何。**所以不需要退回「每个货架一个 item 里套横向 collection view」的嵌套方案。**
  3. orthogonal 段的 `contentInsets.leading/trailing` **不缩窄裁切范围**：内部 scroll view 的 frame 恒为整段宽，内缩是加进它的**文稿**里的。卡片滑出时贴内容列边缘裁掉，与 Music 一致——等同旧版那句`safeAreaPadding(.horizontal, 34)`，不用把内缩挪进 group 的 leading spacing。
  4. 纵向节奏：`NSCollectionLayoutSection.contentInsets.top` 落在**段头与 item 之间**，不在段头上方，所以「上一段卡底 → 本段标题顶」的空白放进本段段头自己的高度里（段头高 = topGap + 标题行高 + 13）。空段（0 item）只占段头那点高，但**别给空段设`interGroupSpacing`**——0 个 group 时那条间距会按 −spacing 记进段高。
  5. 布局配置的**全局头**（`NSCollectionViewCompositionalLayoutConfiguration.boundarySupplementaryItems`）在快照 0 段时会被整个丢掉（AppKit 自打日志`indexPath.section (0) >= numberOfSections (0); ignoring them`），所以页面大标题行做成**恒在的第 0 段的段头**，加载/出错/空态三态下照常显示。
  6. `NSScrollView.contentInsets` 的 setter 会关掉`automaticallyAdjustsContentInsets`（连标题栏那 52 一起丢）。给迷你播放器留白改从`additionalSafeAreaInsets.bottom` 加，自动调整照旧生效、内容照旧能滚到工具栏底下。
- **`NSHostingView` 在表格单元格里的开销**已在歌曲表验证过可接受（只给带控件的格子），详情页曲目行不要沿用，直接 AppKit。
- **测试**：`AppStateForwardingTests` 等依赖`objectWillChange` 的测试不受影响；若阶段 1 把`sidebarVisibility: NavigationSplitViewVisibility` 改成`Bool`，同步改测试。
