# macOS 原生现代化审查与整改单

> 2026-09-17。审查对象：`Amber/**` 全仓（88,777 行 / 220 文件）+ `Support/*.xcconfig` +
> `Amber.xcodeproj`。标尺是 macOS 原生现代化的六个维度：
> **骨架与叶子、响应链、CoreAnimation 直通、Observation 与 Actor 隔离、物理质感、本地优先**。
> 铁律仍以 `AGENTS.md`「界面层」一节为唯一副本。
>
> 与另外两份的分工：[appkit-rewrite-plan.md](appkit-rewrite-plan.md) 管「骨架换成什么」，
> [reactive-ui-review.md](reactive-ui-review.md) 管「换完之后数据怎么流」，
> [swift-modernization.md](swift-modernization.md) 管语言与工具链那一层。
> **这一份管「站在 macOS 平台协议的角度，还欠什么」**——它与前三份的交集是引用关系，
> 不重复结论；凡是前三份已记在案的（如 `reloadData` 与 diffable 的比例），这里只标出处。
>
> 每条都回读核过，行号为 2026-09-17 的 main（68274b9）。

## 0. 诊断

**这份代码的分数是双峰的：凡是架构决策，几乎全对；凡是最后一公里的接线，普遍没接完。**

骨架已经是 AppKit（`Representable` 声明 0、111 个 `NSView`/`NSViewController` 子类对 46 个
SwiftUI `View`）、状态层已经没有 Combine（`import Combine` 0）、渲染已经是零拷贝 CGImage +
`CADisplayLink`、数据层已经是带 10 条索引与 FTS5 的 SQLite。这四件都是需要下决心、花长时间
才能换掉的东西，**都换完了**。

欠的是另一类：窗口白送的 `UndoManager` 一寸没立、四个目录页对键盘用户完全关闭、
首页把已经在内存里的本地内容压在网络菊花后面、铁律 2 唯一被批准的先例自己违反了被批准的条件。
这些都不是架构缺陷，是**接线没接完**——单条工程量都不大，但每一条都直接决定「用起来像不像
系统自带的东西」。

一个副作用值得单记：本仓注释密度 28%、度量出处标记 1,765 条（`[实测]` 793 / `[AX]` 397 /
`[PX]` 311 / `[推]` 240 / `[资源]` 15 / `[Web]` 9），**文档是承重的**。承重的代价是过期文档会
变成错误的前提——§2.1 的第 1 条就是活例子：三段注释从一个不成立的 `sizingOptions = []`
出发，推导出了整套列宽防抖逻辑。

## 1. 评分

| # | 维度 | 分 | 一句话 |
| :-: | --- | :-: | --- |
| 一 | AppKit 骨架 / SwiftUI 叶子 | **9 / 10** | 骨架该是 AppKit 的地方一处不落，`Representable` 清零 |
| 二 | 响应链 | **5 / 10** | 链做得漂亮，**撤销这根柱子整根没有** |
| 三 | CoreAnimation 硬件直通 | **8 / 10** | 零拷贝 + `CADisplayLink` 到位，高刷申请漏了最该申请的那条 |
| 四 | Observation + Actor 隔离 | **8 / 10** | Combine 彻底剥离、订阅层有回归测试；全仓只有 1 个 `actor` |
| 五 | 物理质感与平台归属 | **7 / 10** | 材质与自绘 AX 纪律超出同类；**键盘用户进不去目录页** |
| 六 | 本地优先与增量响应 | **6 / 10** | 地基扎实，最后一公里没接 |
| | **总计** | **7.2 / 10** | |

## 2. 缺口

每条给：证据（文件:行号）、严重程度、修法。已被 §3 认定为「做对了」的不重复。

### 2.1 维度一 · 骨架与叶子

| # | 缺口 | 证据 | severity | 修法 |
| :-: | --- | --- | :-: | --- |
| 1 | **`SongsRichCellView` 的宿主没有 `sizingOptions = []`**，而同文件三段注释把它当既成事实在推理 | 建 host 在 `Components/SongsTableCells.swift:70-84`，全文件无该赋值；注释在 `:24`、`:120`、`:527`，列宽回灌防抖（`:114-130`）正建立在这个前提上 | **高** | `:74` 之后补 `host.sizingOptions = []`，或改走 `appState.hostingView { … }`（`Shell/PageHosting.swift:23` 已代设） |
| 2 | 侧栏播放列表封面是 `NSOutlineView` 复用格子里的 `NSHostingView`，未设 `sizingOptions`，且每次换地址就拆建整棵 SwiftUI 树 | `Views/SidebarOutline.swift:794-826`（`:818` 建、`:833` 手排 frame） | 中 | 照同文件 `:719` 自己的结论（「侧栏就二十来行，纯 AppKit」）改 `NSImageView` + 现成异步取图；过渡期至少补 `sizingOptions = []` 并改成换图不换宿主 |
| 3 | 两处把**静态** SwiftUI 内容挂进表格行（`sizingOptions` 由工厂代设了，问题只是不该在滚动容器里） | `Shell/DetailHeaderViews.swift:1076`（`LosslessBadge`，一行字 + 一颗点）、`Shell/TrackTableViewController.swift:480`（空态，页头是表格第 0 行见 `:275`） | 低 | 徽标换 `NSTextField` + 一颗圆点；空态与 `Shell/LibraryAlbumsViewController.swift:149` 统一成 overlay |
| 4 | **三份零引用的死 SwiftUI 文件仍在编译**，其中含全仓唯一的 SwiftUI 长列表 | `Views/TopSearchLockupView.swift` 整份 214 行（`:20-33` 是 `LazyVGrid`）、`Views/Components/Components.swift:305-397`（`LibraryGridCard`/`MediaCard`）、`Views/MainView.swift` 整份（`:14` 自己写着「现在一处都没有在用了」）。逐符号查过：外部引用**只剩注释**。工程用 `fileSystemSynchronizedGroups`（`project.pbxproj:97`），落盘即入编译 | 中 | 整份删。这三份一删，`Shell/RouteLink.swift` 的 `NavigationLink` 垫片也没有活调用点了，一并删 |
| 5 | 三张资料库网格页用 `NSCollectionViewFlowLayout`，没跟上其余五处的 Compositional，代价是自己接 bounds 通知重排 | `Shell/LibraryAlbumsViewController.swift:36`、`LibraryAllPlaylistsViewController.swift:40`、`LibraryRecentlyAddedViewController.swift:36`；重排在 `Shell/LibraryGridCards.swift:33,91` | 低 | 换 Compositional 的 `.fractionalWidth` 分组，`reflow` 与两条 `NotificationCenter` 观察一起删 |

### 2.2 维度二 · 响应链

#### 缺口 1（本维度最大）：`UndoManager` 全仓 0 处，而 ⌘Z 挂在菜单里恒灰

`App/MainMenu.swift:154-156` 建了「撤销 ⌘Z」/「重做 ⇧⌘Z」，但全仓
`UndoManager` / `registerUndo` / `windowWillReturnUndoManager` **零命中**。
`undo:` 只会被字段编辑器接住，所以在搜索框与改名框之外它恒灰。

本该可撤销而没有的操作：

| 操作 | 入口 | 落库处 | 现状 |
| --- | --- | --- | --- |
| **删除播放列表** | 侧栏右键 `Views/LibraryPlaylistViews.swift:56-61`；网格卡 `Shell/LibraryGridCards.swift:500-505`；页头 ••• `Shell/DetailHeaderViews.swift:676-680,699-701` → `:712-717` | `Services/LibraryStore.swift:469` | **连确认框都没有**，点下即整份消失 |
| **批量心水 / 取消心水** | `Components/TrackMenu.swift:313,319`；`Components/SongsTableCells.swift:472,495,610,615` | `Services/LibraryStore.swift:1013` | 一次改几十首，错了没有回头路 |
| 从歌单移除曲目 | `Shell/TrackTableViewController.swift:510,553` → `Shell/PlaylistDetailViewController.swift:370-383` | `Services/LibraryStore.swift:515` | 无确认无撤销 |
| 从资料库删除歌曲 | `Components/SongsTableView.swift:492-503`；`Components/TrackMenu.swift:400` | `Services/LibraryStore.swift:252` | 有确认框，事后无撤销，且可能连带删本地文件 |
| 从资料库删除专辑 | `Shell/DetailHeaderViews.swift:1206`；`Shell/LibraryGridCards.swift:429`；`Shell/LibraryArtistsViewController.swift:1671` | `Services/LibraryStore.swift:347` | 无撤销 |
| 重排 / 移除待播清单 | `Shell/PlayQueueViewController.swift:760,875-897`；`:793-803` | `Player/PlayQueueModel.swift:301` | 拖错只能手动拖回 |
| 重命名播放列表 | `Shell/RootViewController.swift:228` | `Services/LibraryStore.swift:452` | 旧名当场丢失 |
| 改评分 | `App/AmberApp.swift:182,188`；`Components/TrackMenu.swift` | `Services/LibraryStore.swift:616` | 无撤销 |
| 移除下载 | `Components/TrackMenu.swift:277-279`；`Components/PlayerMoreMenu.swift:116`；`Shell/DetailHeaderViews.swift:1229,1296` | `Services/DownloadStore.swift` | 删的是磁盘文件 |
| 显示简介的字段编辑 | `Shell/InfoPanelWindowController.swift:418-424` | `Services/TrackInfoStore.swift` | 有取消键，「完成」之后无撤销 |

> `Services/LibraryStore.swift:524 moveTracks(fromOffsets:toOffset:inPlaylist:)` **零 UI 调用方**
> ——歌单内拖动重排还没做出来，暂不进表。

**严重程度：高。** 修法：`MainWindowController` 实现 `windowWillReturnUndoManager(_:)`
返回 `AppState` 上的一份；**撤销注册写在 `LibraryStore` / `PlayQueueModel` 的写入口里，
调用点一行不动**（这样批次之间不会互相踩，见 §5）；`setActionName` 之后菜单会自动变成
「撤销 删除播放列表」。批量操作按一次 `beginUndoGrouping` 注册一组。
顺手给「删除播放列表」补确认框——它是全表里唯一一个破坏性且零确认的。

#### 缺口 2–7

| # | 缺口 | 证据 | severity | 修法 |
| :-: | --- | --- | :-: | --- |
| 2 | **铁律 4 点名要删的 `pendingRoute` 仍在**，可变字段当一次性信箱，`.trackGrid` 能带上百个 `Track` 常驻 | `App/AppState.swift:41`、`:808-810`、`:818`、`:835`；订阅方 `Shell/ContentNavigationController.swift:60-64`。**当年的唯一挡路理由已经清零**：`:807` 说的「21 处 `NavigationLink`」现存 2 处，宿主都是 §2.1-4 那三份死代码 | 中 | 死代码删掉之后直接改：`NSResponder` 上一个 `amberOpenRoute(_:)` 由 `ContentNavigationController` 实现，发起方 `tryToPerform` 冒泡。现成同形做法在 `Views/Catalog/AboutPanel.swift:87-97` |
| 3 | 第二个信箱 `pendingLibraryArtistID` 同病 | `App/AppState.swift:48`、`:826`；消费方 `Shell/LibraryArtistsViewController.swift:406,525-527` | 低 | 随上一条收进同一个冒泡意图（`.libraryArtist(id:)` 当一条 Route） |
| 4 | **⌘F 整个不存在** | 全仓 `keyEquivalent: "f"` 只有 `App/MainMenu.swift:192` 的 ⌃⌘F 全屏；编辑菜单（`:151-167`）无「查找」。页内搜索框只能鼠标点，或靠 `Shell/PageHosting.swift:278` 的 `focusToken` 上屏自动回焦 | 中 | 编辑菜单加「查找 ⌘F」，`target = nil`，实现在各带搜索框的页控制器上（`Shell/ContentToolbar.swift` 的 `SearchFieldBinder.focus()` 现成），不在这类页时自动置灰 |
| 5 | 「查看显示选项…」**永远点亮且实现放错了层** | 建项 `App/MainMenu.swift:180`，实现在 `App/AmberApp.swift:140`（AppDelegate），而 `validateMenuItem` 的 switch（`:239-289`）没有这一支，落到 `default: return true`。它只对歌曲表有意义（`Shell/SongsViewOptionsPanelController.swift:4` 自述对应 Music 的 `ViewNSMenuHelper`）。在主页点它会弹一扇调不到任何东西的面板 | 中 | 把 `amberShowSongsViewOptions` 从 AppDelegate 挪到 `Shell/LibrarySongsViewController`（与 `amberShowHideDuplicates` 并排），响应链自动置灰，一行 validate 都不用写 |
| 6 | **⌫ 删除是在 `keyDown` 里裸接的**，不是可验证的菜单命令 | `Components/SongsTableView.swift:889-909`（`case 51:` 不看修饰键）→ `:492`；编辑菜单那条「删除」（`App/MainMenu.swift:162`）绑的是 `NSText.delete(_:)`，与曲目删除无关 | 中 | 提成 `amberDeleteSelection(_:)` 页面级命令，编辑菜单改绑它——验证、撤销 action name 一次到位（与缺口 1 同根） |
| 7 | ⌘I 在「资料库 › 艺人」页恒灰，而同一页行右键里有「显示简介」 | `amberGetInfo` 只实现在 `Shell/TrackTableViewController.swift:573` 与 `Shell/LibrarySongsViewController.swift:353`；`Shell/LibraryArtistsViewController.swift:29` 继承 `ContentPageController` 未实现，但行菜单走 `TrackActions`（`:1942,2070`）含 `Components/TrackMenu.swift:305` 那条 | 低 | 该页补一份 `amberGetInfo` + validate，作用集取当前高亮行 |
| 8 | 「进入全屏幕」标题不会翻 | `App/MainMenu.swift:190-194` 固定标题，全仓无「退出全屏幕」，也无接 `toggleFullScreen:` 的 validate 分支（对照边栏那条 `App/AmberApp.swift:285` 是手工翻的） | 低 | validate 里按 `window.styleMask.contains(.fullScreen)` 翻，或改用 AppKit 标准全屏项 |

### 2.3 维度三 · CoreAnimation

| # | 缺口 | 证据 | severity | 修法 |
| :-: | --- | --- | :-: | --- |
| 1 | **驱动歌词每帧的 `CADisplayLink` 自己没申请高刷** ——而滚动弹簧与逐字染色正是由它推的，不是 CA 动画 | 建链 `Lyrics/SyncedLyricsViewController+Setup.swift:422-427` 无 `preferredFrameRateRange`；每帧推进在 `:442-463`。对照 `Lyrics/LayerPropertyAnimator.swift:117,182` 逐条动画都写了 120Hz | 中 | 建链后补 `link.preferredFrameRateRange = LayerPropertyAnimator.frameRateRange(min: 0, max: 0)`，复用现成工厂 |
| 2 | 整棵歌词子树关掉进程外渲染 | `Lyrics/SyncedLyricsLineView+View.swift:28` `layerUsesCoreImageFilters = !LyricsDebugFlags.disablesLayerFilters`（开关是 `-nolyricsfilters` 启动参数，正常运行为开）；每行挂 `CIGaussianBlur` + `CIColorControls`（`Lyrics/SyncedLyricsLineLayer+Focus.swift:72-90`） | 中 | `Lyrics/SyncedLyricsVisualExperienceManager+Selection.swift:496-516` 已按播放态整表开关模糊，顺手把「模糊量为 0 的行」`filters = nil` 并关掉该行的 `layerUsesCoreImageFilters` |
| 3 | 两个 MiniPlayer 封面缺内存缓存快路径，每次换歌必白一帧 | `Shell/MiniPlayerView.swift:939-943`、`Shell/MiniPlayerContentView.swift:1560-1566` 都是「`contents = nil` → 起 Task → await」。`Services/ImageCache.swift:44-45` 明写了这条路的代价，`memoryCachedImage(for:)` 就是为此加的，`Catalog/CatalogCardItems.swift:223` 与 `Catalog/ArtistPageCards.swift:303` 都用了，这两处漏了 | 中 | 照 `CatalogCardItems.swift:223-226`，置 nil 之前先查内存缓存，命中就同步贴 |
| 4 | **本地 `file://` 封面零降采样** | `Services/ImageCache.swift:127-139` 恒按原尺寸解码；`CreateThumbnail` / `ThumbnailMaxPixelSize` / `prepareForDisplay` 全仓零命中；`:120-122` 自认「40pt 的行、240pt 的块、400pt 的头共用同一个 NSImage」。内嵌封面常见 1500–3000px | 中 | `decode` 加 `maxPixelSize` 入参，`file://` 支路（`:60-66`）走 `CGImageSourceCreateThumbnailAtIndex`，缓存键带上档位。**网络封面不用动**——`Services/ArtworkSize.swift:20-32` 的六档已经很好 |
| 5 | 两处 CI 烘焙跑在主线程的 `layout()` 里 | `Shell/MiniPlayerContentView.swift:1411` → `:1473` `ciContext.createCGImage`；`Catalog/ArtistPageCards.swift:361` → `:408`/`:427` 两次，其中一次含 `CIGaussianBlur(radius: 36)` 渲整页画布。两者都有尺寸缓存闸，但实时拖窗每一档新尺寸都要同步烘一次 | 中 | 搬到 detached task，算完回主线程贴 `contents`，期间旧画布继续显示 |
| 6 | 自绘滑块圆钮有阴影无 `shadowPath`，拖动中每帧离屏 | `Shell/NowPlayingChromeViews.swift:784-787`、`Shell/MiniPlayerView.swift:1177-1180`；frame 在 `mouseDragged` 里逐事件重排 | 低 | `layoutBars` 末尾补 `shadowPath`，与 `Catalog/CatalogCardItems.swift:353` 同法 |
| 7 | 两处主线程重绘位图 | `Views/SidebarOutline.swift:298-300`（QQ 头像）、`Shell/InfoPanelWindowController.swift:820`（`image.draw(in:)` 画封面） | 低 | 换 `CALayer.contents = cgImage` + `contentsGravity`，`CatalogArtworkView` 是现成模板 |
| 8 | 倍率取 `NSScreen.main` 而非所在窗口的屏 | `Services/ArtworkSize.swift:19`、`Lyrics/LyricsRenderingScale.swift:16`。歌词那边有 `Lyrics/SyncedLyricsLineView.swift:51-62` 兜底，封面这边没有 | 低 | `ArtworkSize.url` 加 `scale:` 入参，调用点传 `view.amberWindow?.backingScaleFactor` |

### 2.4 维度四 · Observation 与 Actor 隔离

| # | 缺口 | 证据 | severity | 修法 |
| :-: | --- | --- | :-: | --- |
| 1 | **全仓只有 1 个 `actor`**，SQLite 连接层与 FTS 搜索整个压在 `@MainActor` 上 | 唯一 actor `Providers/RequestCache.swift:11`；`@globalActor` 0 处；`Services/AmberDatabase.swift:16` 与 `Services/SQLiteDatabase.swift:186-188` 自述「所有访问都在 `@MainActor` 的 store 里」；FTS 同步查询 `Services/LibraryStore.swift:1962-1972`。真正离开主线程的只有 `ImportService` / `ImageCache.decode` / `LoudnessStore.scan` 三条 | 中 | 把 `AmberDatabase`/`SQLiteDatabase` 收进一个 `actor`（连接本就只有一条、语句缓存已私有），store 保持 `@MainActor` 但读写 `await`。**先只搬只读的 `loadFromDatabase` 与 `searchFilter` 两条路。**工程量大，§5 里单列 |
| 2 | `PlayerController` 49 个可观察存储属性、`@ObservationIgnored` **0 个**（核实：`grep -c` = 0） | `Player/PlayerController.swift:124-292`，其中 14 个是纯接线闭包（`providerResolver:159`、`onSkip:170`、`onTrackPlayed:178`、`loudnessProvider:180`…），另 20 余个是播放内部账本（`failureStreak:261`、`queueVersion:267`、`shuffleCursor:259`…）。同族的 `Services/LibraryStore.swift` 标了 10 个 | 中 | 14 个闭包 + `deckA/deckB/current/endObserver/observers/autoplayTask/scanTask` 一律加 `@ObservationIgnored` |
| 3 | `DownloadStore` 18 个可观察属性也是 0 个 | `Services/DownloadStore.swift:79-130`（`resolveRemoteURL:83`、`onDownloaded:98`、`settings:109`、`database:125` 全是注入依赖或回调） | 低 | 同上 |
| 4 | `AppState` 31 个可观察属性里只有 11 个是真界面状态 | `App/AppState.swift:13-114`，只有 `importService:94` 标了 `@ObservationIgnored` | 低 | `let` 依赖与三个 `private var` 内部账加标注 |
| 5 | **`AppSettings.values` 是 37 字段单体**，任何一项偏好变动惊动全部订阅者 | 唯一可观察属性 `Services/AppSettings.swift:428`；订阅整份的 3 处：`App/AppState.swift:378`、`Components/SongsTableSettings.swift:141`、`Player/PlayQueueModel.swift:124`。改一次歌词字号会把「有效音质重算」与「待播清单重算」一起叫醒 | 中 | 三处改成投影出自己真读的那几项。同文件 `Player/PlayerController.swift:320` 的 `AudioPrefs(...)` 已经是正确形状 |
| 6 | `observeAny` 用的是 `dropFirst()`——正是存档记的那条会吞改动的写法，21 个调用点 | `Observation/TaskBag.swift:100`；`:91-94` 承认了并论证「消费方都是幂等的 `setNeedsRefresh()`」，但 `Player/PlayQueueModel.swift:107` 与 `Lyrics/InspectorLyricsViewController.swift:578` 不是 | 中 | 给 `observeAny` 也加基线（元组不 Equatable 就存版本号），或至少把这两处换成显式 `observe` |
| 7 | `App/AppState.swift:386`、`:392` 两条订阅绕开 `TaskBag.observe` 直接写 `Observations{}.dropFirst()` | 同上 | 低 | 包成 `TaskBag.observeDistinct(by:)`，基线逻辑只留一份实现 |
| 8 | `TaskBag.tasks` 只增不减 | `Observation/TaskBag.swift:11,15-17` | 低 | `add` 时顺手清掉已取消的 |
| 9 | `EventChannel` 无界缓冲且无观测口 | `Observation/EventChannel.swift:33` `bufferingPolicy: .unbounded`（理由在 `:15-16`）。但 `LibraryStore.notify` 在批量入库时会连发上百条 | 低 | 改 `.bufferingNewest(64)`（掩码型事件语义无损），或 DEBUG 下对深度加断言 |
| 10 | `TapShared.dsp` 是 13 个 `Atomic` 兄弟里**唯一的裸指针** | `Player/AudioTap.swift:135`，兄弟在 `:94-126`；类整体 `@unchecked Sendable`（`:91`）。**不是 use-after-free**——契约 ③（`:33-38`）写明 MediaToolbox 对同一支 tap 的 prepare/process/unprepare 串行下发，这是平台保证。但它是全仓唯一靠外部时序假设而非类型系统兜住的字段 | 低 | 换 `Atomic<UInt>` 存指针位模式，与兄弟一致，零成本 |
| 11 | `ImportTranscoder` 26 处 `unsafe` 源自 5 个 `nonisolated(unsafe)` 局部声明，触到二档判据（同一声明 ≥3 次）却没做外壳 | `Services/ImportTranscoder.swift:306,307,315,319,336`；`:300-305` 自己也写了这条 | 低 | 收进一个 `@safe struct TranscodeSession` 把 5 个句柄一起包住 |
| 12 | `SWIFT_STRICT_MEMORY_SAFETY` 只在工程级出现一次，而另三条开关在 target 级重复写着 | `Support/SwiftFeatures.xcconfig:66` vs `project.pbxproj:284-287` 等。继承链是对的，但以后谁在 target 上加一行 `OTHER_SWIFT_FLAGS` 忘了 `$(inherited)` 就会静默丢掉 `ImmutableWeakCaptures` | 低 | 按 xcconfig 头上 `:3-6` 自己写的理由，把那三条也搬进 xcconfig，target 级清零 |

### 2.5 维度五 · 物理质感与平台归属

| # | 缺口 | 证据 | severity | 修法 |
| :-: | --- | --- | :-: | --- |
| 1 | **目录侧四页对键盘用户完全关闭** | `Shell/CatalogPageViewController.swift:248`、`Shell/CatalogRoomViewController.swift:155`、`Shell/SearchLandingViewController.swift:95` 三处 `collectionView.isSelectable = false`，方向键选择被关死；对照资料库三页是 `true`（`LibraryAlbumsViewController.swift:48` 等）。同时全仓 `acceptsFirstResponder` 只有 1 处且在注释里（`Shell/InfoPanelForm.swift:759`），卡片基类 `Catalog/CatalogCardItems.swift:528-546` 不进键视图循环、无焦点环 | **高** | 三处改 `true` 并实现 `collectionView(_:didSelectItemsAt:)` 把回车/空格接到已有的 `item.route`/`onOpen`/`onPlay`；焦点环用 `NSCollectionViewItem.isSelected` 驱动现成的 `hoverDidChange` |
| 2 | 两条播放进度滑块报了 `.slider` 却从不写 `accessibilityValue` | `Shell/MiniPlayerView.swift:1054-1056`、`Shell/MiniPlayerContentView.swift:1867-1869` 只设 element/role/label；对照两条音量条在 `layoutBars` 末尾就写了（`MiniPlayerView.swift:1214`、`NowPlayingChromeViews.swift:823`）。而 increment/decrement 又是接了的（`:1137-1145`/`:1954-1962`），按了不知道跳到哪 | 中 | 两处 `layoutBars` 末尾各补一句 `setAccessibilityValue`，配合宿主的时长格成 mm:ss |
| 3 | 歌词行的 AX 标签丢掉副行，滚动容器没报 `.list` | `Lyrics/SyncedLyricsLineView+View.swift:41-48` 只回正文，而界面上画着翻译与发音两条副行（`Lyrics/TextContentLayer.swift:23-24`）。开了翻译的 VoiceOver 用户读不到译文 | 中 | 把 `TextContentLayer` 已有的译文/发音串接进 `accessibilityText`；文档视图给 `setAccessibilityRole(.list)` |
| 4 | **`NSUserActivity` / Handoff / Spotlight 一处都没有** | `NSUserActivity`、`CSSearchable*`、`CoreSpotlight` 全仓零命中 | 中 | 先在专辑/艺人/歌单三个详情 VC 的 `viewDidAppear` 挂 `NSUserActivity`（`isEligibleForHandoff`/`ForSearch`），`userInfo` 存路由标识 |
| 5 | `state = .active` 三处只有一处有实测依据（违反铁律 6） | `Shell/RootViewController.swift:44-45` 写了「Music 不是这样」算站得住；`:251`（Toast）与 `Shell/MiniPlayerContentView.swift:486-487` 只写了观感 | 低 | Toast 那处删掉（HUD 本就该跟随窗口激活态）；迷你窗那处补实测编号或降级标成 `[推]` |
| 6 | 「按住持续发射」的两端控件 AX 语义不对 | `Shell/NowPlayingChromeViews.swift:719-721` 报 button + label，但它自接 mouseDown/mouseUp（`:738-745`），VoiceOver 默认 press 只走一次 | 低 | 实现 `accessibilityPerformPress`，label 改成描述动作而非符号 |
| 7 | 没有任何地方响应「减弱透明度」 | `accessibilityDisplayShouldReduceTransparency` 全仓零命中。`NSVisualEffectView`/`NSGlassEffectView` 自己会降级，但 `Shell/MiniPlayerBackdropMetalView.swift` 那块自绘 Metal 底衬只看了 reduce-motion（`:87-89`） | 低 | 在 `:264` 的偏好观察点一并读，命中就退回 `Shell/MiniPlayerContentView.swift:480-488` 已有的 `NSVisualEffectView` 分支 |

### 2.6 维度六 · 本地优先与增量响应

| # | 缺口 | 证据 | severity | 修法 |
| :-: | --- | --- | :-: | --- |
| 1 | **首页把已经在内存里的本地内容压在网络菊花后面** | `Catalog/CatalogFeedModel.swift:82` 先置 `.loading`，`Shell/CatalogPageViewController.swift:635-637` 收到后 `showOverlay(.loading)` **并 `apply(sections: [])` 清空集合视图**；而「最近播放」与「音乐回忆」两段纯由 `LibraryStore` 同步算出、在 `:87-92` 被明确排除出网络组，却要等 `:94-114` 那个并发上限 4、十几段的 `withTaskGroup` 整个排干才在 `:132` 一起发布。离线时等完还落到**空态**而非错误态 | **高** | 两段本地内容在置 `.loading` 之前先 `apply` 一次，网络段到货再增量补进去。同仓正例：`Shell/CatalogRoomViewController.swift:322-332`「留旧内容、菊花盖上去」 |
| 2 | 本地专辑 / 已镜像歌单也吃一次没必要的菊花 | `Shell/AlbumDetailViewController.swift:82` 无条件 `apply(state:.loading)` 之后才在 `:84-89` 分支出 `album.isLocal` 的同步读；`Shell/PlaylistDetailViewController.swift:439` 同形。清空动作在 `Shell/TrackTableViewController.swift:276-278` | 中 | `.loading` 移到 `isLocal` 分支之后 |
| 3 | **18 个页面级控制器里只有 4 个用增量快照** | diffable 在 `Shell/CatalogPageViewController.swift:739`、`CatalogRoomViewController.swift:391`、`SearchLandingViewController.swift:228`、`PlayQueueViewController.swift:498`。`reloadData()` 8 处，其中三张资料库网格页**已经有稳定 id 与现成分段**：`LibraryAlbumsViewController.swift:125`、`LibraryAllPlaylistsViewController.swift:124`、`LibraryRecentlyAddedViewController.swift:161`（`:160` 已分好 sections）。另 `LibraryArtistsViewController.swift:471` 左表可换。详见 [reactive-ui-review.md §2.3](reactive-ui-review.md) | 中 | 先做那三张 collection view，改造量最小、收益最直接（滚动位置与选中态不再被整表重载抹掉）。`Components/SongsTableView.swift:111`（已有三重闸门）与 `Views/SidebarOutline.swift:405`（已有变更闸门）**判定：不必改** |
| 4 | **整座资料库在首帧之前、主线程上同步读完** | `AppDelegate` 的存储属性 `let appState = AppState()`（`App/AmberApp.swift:43`）在 `applicationDidFinishLaunching` 之前触发；`Services/LibraryStore.swift:218-221` 同步串起「迁移 → 开库 → `load()`」，而 `loadFromDatabase`（`:1268-1379`）是曲目全表 + 5 张关系表 + `playlist_track` + `track_stat` 一整趟 | 中 | `load()` 拆成「同步只读头 N 行喂首屏」+「其余异步补齐后一次 `notify`」；或至少把 `track_stat`/`recent_*` 挪到 `runLaunchTasksOnce` |
| 5 | 两条启动任务在主 actor 上做同步磁盘遍历 | `downloads.renameLegacySuffixedFiles()`（`App/AppState.swift:551` → `Services/DownloadStore.swift:706-738`，逐条 `fileExists` + `moveItem` 全同步）；`measureDownloadedTracks()`（`App/AppState.swift:570-575`）遍历整份 `libraryTracks` | 中 | 文件系统那段整段 `nonisolated`，只把 `[(id, newPath)]` 回主 actor 写索引。`Services/ImportService.swift:320-728` 已经是这个形状，照抄 |
| 6 | **下载会话一个超时都没设** | `Services/DownloadStore.swift:1559-1560` 直接用 `URLSessionConfiguration.default`；`timeoutIntervalForResource` **全仓一处都没设过**（资源级默认 7 天）。一条卡死的下载会挂到进程退出 | 中 | 设 `timeoutIntervalForRequest = 30` + `timeoutIntervalForResource`（按最大文件估，如 600 s） |
| 7 | 重试逻辑几乎为零 | 全仓唯一的网络重试是 `Providers/Netease/NeteaseAPI.swift:288-295`（匿名 token 注册，2 次无退避）。目录、搜索、歌词、取流、封面、下载一次都不重试 | 中 | provider 的 `get` 那层加「仅对 `URLError` 连接类错误、最多 2 次、指数退避」的包装；业务错误（104003 之类）不重试 |
| 8 | **离线与「音源没内容」在界面上分不开，且没有重试按钮** | 全仓 0 处 `NWPathMonitor` / `URLError.notConnectedToInternet`；`CatalogFeedModel` 连 `.error` 分支都没有，取不到就 `.empty`，最终落到「当前音乐源暂无推荐内容。」（`Catalog/CatalogFeedModel.swift:49` → `Shell/CatalogPageViewController.swift:642-643`）。这与 [reactive-ui-review.md 故障 7](reactive-ui-review.md) 同病，那次只修了搜索 | 中 | `CatalogFeedModel` 增 `.error(retry:)` 态，从错误码认出连接类错误说「网络不可用」并给重试。不必引入 `NWPathMonitor` |
| 9 | `RequestCache` 条目永不淘汰 | `Providers/RequestCache.swift:17,37-39`——过期条目只被同键覆盖，无清扫无上限。键带分页参数，长会话翻页越多留得越多 | 低 | `value(for:)` 开头顺手扫一次过期，或加 200 条上限 |
| 10 | `ImageCache` 磁盘缓存无容量上限 | `Services/ImageCache.swift:31` 只有 30 天 TTL，`:155-176` 每进程跑一次且只按时间；内存有 `countLimit`/`totalCostLimit`（`:38-39`）而磁盘没有对应物 | 低 | 清扫时按总字节排序，超阈值（如 512 MB）从最旧删 |

## 3. 六个维度之外

这四条不属于上面任何一维，但都直接关系「像不像一个现代 Mac 软件」。

| # | 缺口 | 证据 | severity |
| :-: | --- | --- | :-: |
| 1 | **零本地化** | 无 `.lproj`、无 `.xcstrings`，中文硬编码；`Support/Info.plist` 的 `CFBundleDevelopmentRegion = zh-Hans` | 中 |
| 2 | **零沙盒**，且一刀切关掉 ATS | 全仓无 `.entitlements` 文件；`Support/Info.plist` 的 `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` | 中 |
| 3 | **零 CI、零 signpost** | 无 `.github/`；1,119 个测试（78 文件）只能手工跑，且全是 XCTest、`swift-testing` 零使用。一个把帧预算写进验收标准的项目却没有 Instruments 埋点；日志混着 `NSLog`（10 处）与 `os.Logger`（4 处） | 中 |
| 4 | **文档漂移** | `README.md:5` 仍写「**零第三方依赖**」，而 `Package.resolved` 里有 `swift-async-algorithms` 1.1.5 + `swift-collections` 1.6.0；`README.md:161-162` 说「过渡期仍是 SwiftUI 的那几页由 `NSHostingView` 包着」，而阶段 1–7、9 都已完成。**103 处注释还在讲仓里已经不存在的 `@Published` / `receive(on:)` / `objectWillChange`**，其中会误导人的至少三处：`App/AppState.swift:366`、`Shell/AuxiliaryWindows.swift:58`、`Shell/LibraryAlbumsViewController.swift:128` | 中 |

> 多数历史注释（「原来的理由是…现在是…」）是**有价值的**，不在此列。要清的只有两类：
> **把已废事实当现行前提用的**（§2.1-1 那三段是典型），以及 **README 里对外的事实性陈述**。

## 4. 已经做对的，别动

1. **响应链**：主菜单 22 条命令全部 `target = nil`（构造器 `App/MainMenu.swift:278-290`，理由 `:5-17`）；两条命令（⌘I、显示重复项目）刻意做成页面级，靠链上有没有人接来自动置灰（`:26-29,38-41`）；工具栏「返回」这类窗口级命令才 `target = self`（`Shell/MainWindowController.swift:286-287`）。分工清楚。
2. **零 EventBus**：自定义 `Notification.Name` **0 处**，现存 `NotificationCenter` 用法全是系统通知。
3. **Esc 三层冒泡**：`Shell/RootViewController.swift:180-191` → `Shell/ContentToolbar.swift:582-588` → `:440-443`，且会继续往上让路。
4. **无修饰空格的抢占顺序有独立探针实测背书**：`App/AmberApplication.swift:49-76`，派发表在 `:9-13`；唯一让路的是 `NSTextInputClient`，只读 `NSTextView` 不算（`:73-75`）。
5. **意图冒泡的现成样板**：`Views/Catalog/AboutPanel.swift:87-97` 沿 `amberNextResponder` 上溯找宿主、不持引用——§2.2-2 直接抄它。
6. **`LibraryStore` 的 11 位变更掩码 + `changes(affecting:)`**（`Services/LibraryStore.swift:19-44,185`），`changeChannel` 私有（`:176`），不留「订上就什么都收」的口子。
7. **`TaskBag.observe` 在调用点同步取基线**再比对首元素（`Observation/TaskBag.swift:54,59-63`），并配了三条回归测试钉死（`AmberTests/Observation/ObservationInfraTests.swift:44-58,60-77,85-95`）。
8. **`@concurrent` 标满整个 `MusicProvider` 协议**（`Providers/MusicProvider.swift:37-138`，17 处，理由 `:29-31`）——这是音源层能真正离开主线程的关键一笔。
9. **`unsafe` 三档纪律**：二档 `@safe` 外壳 9 处各记「≥3 次」判据（`Safety/AppKitSafeAccess.swift`），三档只用于本身就是不安全契约的函数（AudioTap 的 `@convention(c)` 实时回调）。`@preconcurrency` **0 处**。
10. **必须贴 `CGImage` 而不是 `NSImage`** 的理由是踩过的现象不是惯例（`Catalog/CatalogCardItems.swift:250-252`）；6 个 `layer.contents` 写入点全部合规。
11. **8 处 `Timer` 无一是渲染循环**；唯一 `repeats: true` 那个（`Components/ReactionEffect.swift:170`）只负责 4.5 Hz 造粒子，运动整条交给 `CAKeyframeAnimation`（`:106-125`）。
12. **Metal 底衬主动限帧省电**（`Shell/MiniPlayerBackdropMetalView.swift:138` 15 fps，取值理由在 `DesignSystem/MusicMetrics.swift:766-768`），并按可见性/有无封面开关（`:298`）。
13. **故意不用 `.sidebar` material**：`Shell/RootViewController.swift:7-10` 与 `Views/SidebarOutline.swift:49` 记了实测——侧栏自己糊会渲成恒定浅灰 #4E4D4B，玻璃必须由窗口根给。
14. **自绘 CALayer 全都补了 AX**：四条自绘滑块 role/label/increment 三件套齐全，歌词行报 `staticText` 且选中态随播放推进，装饰层显式移出 AX 树（`Components/ReactionEffect.swift:72`、`Components/TrackRowParts.swift:269`）。
15. **增强对比度走外观档解析**而非读全局布尔（`DesignSystem/MusicColors.swift:21-37`）；减弱动态效果在 10+ 处降级，含自绘 Metal。
16. **顶部内缩交给系统 `safeAreaLayoutGuide`** 而不是写死 52（`Shell/CatalogPageViewController.swift:265-270` 等），故意越过安全区的地方标了理由（`Shell/MiniPlayerContentView.swift:616-628`）。
17. **SQLite 配置**：`WAL` + `synchronous=NORMAL` + `foreign_keys` + `busy_timeout` + 退出 `wal_checkpoint(TRUNCATE)`（`Services/SQLiteDatabase.swift:241-247,347`）；10 条索引含部分索引；FTS5 一张虚表服务四类搜索（`Services/AmberDatabase.swift:420-443`）并按 CJK 教训做了空格插值 + 短语邻近 + 拼音（`Services/LibrarySearch.swift:5-27,174-221`）。
18. **降级设计是真的**：搜索查询抛错就退回内存筛选（`Services/LibraryStore.swift:1955-1971`），库开不了就只读不写（`:1245-1251`），四个 store 同规矩。
19. **封面档位是从 Music 反出来的实测值**（`Services/ArtworkSize.swift:20-32`，40/44/150/225/400/800 对应 `desiredArtworkPixelSizeForItem:`/`ArtistAvatarModel`/`PlaylistArtworkLoader`/`ITMPMetadataModel`）。
20. **`apply` 的 completion 里不许 `noteHeightOfRows`**（`Shell/PlayQueueViewController.swift:492-497`，附崩溃原委）。

## 5. 整改批次

按文件所有权切，各批文件**不重叠**，可并行。
**关键约定：撤销注册写在 `LibraryStore` / `PlayQueueModel` 的写入口里，调用点一行不动**
——批 C 因此不需要碰批 A/B/E 的文件。

| 批 | 主题 | 覆盖 | 文件 | 状态 |
| :-: | --- | --- | --- | --- |
| **A** | 铁律 2 收口（= 计划阶段 8 的其余部分） | §2.1-1、-2、-3 | `Components/SongsTableCells.swift`、`Views/SidebarOutline.swift`、`Shell/DetailHeaderViews.swift`、`Shell/TrackTableViewController.swift` | 未开始 |
| **B** | 意图上响应链（= 铁律 4 的终态） | §2.2-2、-3、-7 | `App/AppState.swift`、`Shell/ContentNavigationController.swift`、`Shell/LibraryArtistsViewController.swift` | 未开始 |
| **C** | 撤销与命令层 | §2.2-1、-4、-5、-6、-8 | `App/MainMenu.swift`、`App/AmberApp.swift`、`Shell/MainWindowController.swift`、`Services/LibraryStore.swift`、`Components/SongsTableView.swift`、`Components/TrackMenu.swift`、`Shell/LibrarySongsViewController.swift`、`Shell/PlayQueueViewController.swift`、`Player/PlayQueueModel.swift` | 未开始 |
| **D** | 本地优先最后一公里 + 目录页键盘可达 | §2.6-1、-2、-8；§2.5-1 | `Catalog/CatalogFeedModel.swift`、`Shell/CatalogPageViewController.swift`、`Shell/CatalogRoomViewController.swift`、`Shell/SearchLandingViewController.swift`、`Shell/AlbumDetailViewController.swift`、`Shell/PlaylistDetailViewController.swift` | 未开始 |
| **E** | 增量快照三页 + Compositional | §2.6-3；§2.1-5 | `Shell/LibraryAlbumsViewController.swift`、`Shell/LibraryAllPlaylistsViewController.swift`、`Shell/LibraryRecentlyAddedViewController.swift`、`Shell/LibraryGridCards.swift` | 未开始 |
| **F** | 渲染与 AX 收尾 | §2.3 全部；§2.5-2、-3、-6、-7 | `Lyrics/**`、`Shell/MiniPlayerView.swift`、`Shell/MiniPlayerContentView.swift`、`Shell/NowPlayingChromeViews.swift`、`Shell/MiniPlayerBackdropMetalView.swift`、`Services/ImageCache.swift`、`Services/ArtworkSize.swift`、`Catalog/ArtistPageCards.swift` | 未开始 |
| **G** | 观察粒度 + 网络韧性 | §2.4-2~9、-11、-12；§2.6-5、-6、-7、-9、-10 | `Player/PlayerController.swift`、`Player/AudioTap.swift`、`Services/DownloadStore.swift`、`Services/AppSettings.swift`、`Services/ImportTranscoder.swift`、`Observation/TaskBag.swift`、`Observation/EventChannel.swift`、`Providers/RequestCache.swift`、`Providers/MusicProvider.swift`、`Support/SwiftFeatures.xcconfig` | 未开始 |

### 切批前主会话定下的四条（2026-09-17）

1. **接缝已做**（提交 `ee65d2c`）：§2.1-4 的四份死代码由主会话一次删完，A–G 从同一棵树起步。
   照 [reactive-ui-review.md §4](reactive-ui-review.md) 的 `SidebarItem.playlist` 那次办法。
2. **原尾注的疑问已解**：`Components/TrackRowParts.swift` 里零 `SongsTable*` 引用，A 与 C 不撞。
3. **批 B 只改函数体，一个调用点都不动。** `appState.push` / `goToAlbum` / `goToArtist` 有
   **25 个活调用点散在 12 个文件里**，横跨 A/C/D/E/F 五个批次——让 B 去改调用点等于把七批串成一条线。
   所以 `AppState` 上那三个方法的**签名与调用点全部保留**，只把函数体从「置 `pendingRoute`」
   换成 `NSApp.sendAction(_:to: nil:from:)` 走响应链，`ContentNavigationController` 那头改成
   实现 `amberOpenRoute(_:)`。这也顺带把 diff 缩到两个文件。
4. **`Player/PlayQueueModel.swift` 归 C 不归 B。** 撤销要挂在它的写入口（`doDeleteAction:301`、
   `doReorder:330`），而 B 按第 3 条已经不需要碰它（`:225` 那处 `appState.push` 原样不动）。

### 并发约束（每个子代理都要守）

- **不许跑 `xcodebuild test`。** 两个 worktree 同跑会互相杀宿主，日志长得像自己代码崩了
  （记忆 `am-concurrent-xcodebuild-test-kills-host`）。各批只跑 `xcodebuild build` 验编译，
  **`AmberTests` 由主会话在合并后串行跑一次**。
- 各自独立 `-derivedDataPath`，**不启动 App**（记忆 `delegate-to-opus-few-agents`）。
- 实机 `./Tools/run.sh` 也只由主会话在合并后跑（同 bundle id 多份会让 LaunchServices 命中不确定）。

### 单列（不进批次，各自一条）

| 项 | 为什么单列 |
| --- | --- |
| **SQLite 收进 `actor`**（§2.4-1） | 横跨 `AmberDatabase`/`SQLiteDatabase`/四个 store，是整轮里唯一的结构性改动，不能与别的批并行 |
| **资料库启动读盘拆成两段**（§2.6-4） | 同上，与前一项是同一棵树 |
| **本地化**（§3-1） | 横跨全仓每个字符串字面量，工程量与性质都与其余不同 |
| **CI + signpost + 日志归一**（§3-3） | 不改产品代码，随时可做 |
| **`LoudnessStore.scan` 吃满一核** | [reactive-ui-review.md §5](reactive-ui-review.md) 已记，仍未处理 |

### 收工标准（每批都要）

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` + `-derivedDataPath build/DerivedData`（见 `AGENTS.md`）
- `AmberTests` 全绿；跑测试会碰真实偏好与真实资料库，测试期数据可随意改
- 改了界面骨架的批次，合回前由主会话跑一次 `./Tools/run.sh` 实机起一遍（**编译过 ≠ 能起来**）
- **像素一个不改**：这一轮只动行为与数据流，不动版式。批 A 的三处视图替换（侧栏封面、徽标、空态）要用 `-dumpviews` 对前后 frame
- 每批顺手清掉**自己文件里**的陈旧注释（§3-4），不跨批改
- 新增/改动的度量按铁律 5 标出处；新碰裸指针的按 `AGENTS.md` 三档选，不许跳档

## 6. 要用户实机点的

鼠标与键盘类验收（按 `am-interaction-tests-by-user`，键盘类可由 System Events 自证，鼠标类交给用户）：

1. **键盘**：主页用 Tab 进入网格，方向键在卡片间移动，回车打开——现在方向键完全没反应（§2.5-1）。
2. **键盘**：任意页按 ⌘F，搜索框应该获得焦点（§2.2-4，现在什么都不会发生）。
3. **键盘**：删掉一份播放列表后按 ⌘Z（§2.2-1，现在是灰的）。
4. **鼠标**：断网状态下切到主页——「最近播放」与「音乐回忆」应该**立刻**显示，不该等整页网络（§2.6-1）。
5. **鼠标**：断网状态下主页应该显示「网络不可用」+ 重试按钮，而不是「当前音乐源暂无推荐内容。」（§2.6-8）。
6. **鼠标**：在主页点「查看显示选项…」——现在会弹一扇调不到任何东西的面板（§2.2-5）。
7. **鼠标**：资料库专辑页滚到中段，让一次入库发生——滚动位置与选中态不该被抹掉（§2.6-3）。
8. **鼠标**：迷你播放器换歌——封面不该白一帧（§2.3-3）。
9. **VoiceOver**：焦点落到播放进度条上，应该念得出当前位置（§2.5-2）。
